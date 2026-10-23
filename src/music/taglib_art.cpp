// C shim exposing TagLib's embedded-art extraction (and a folder-cover
// fallback) through a small C interface, mirroring the C++ original's
// LibraryScanner::extractCoverArtFromFile / findAlbumCoverInFolder.
// Compiled as C++ and linked into the frontends alongside libtag.

#include "taglib_art.h"

#include <taglib/attachedpictureframe.h>
#include <taglib/fileref.h>
#include <taglib/flacfile.h>
#include <taglib/flacpicture.h>
#include <taglib/id3v2tag.h>
#include <taglib/mp4coverart.h>
#include <taglib/mp4file.h>
#include <taglib/mp4tag.h>
#include <taglib/mpegfile.h>
#include <taglib/opusfile.h>
#include <taglib/vorbisfile.h>
#include <taglib/tag.h>
#include <taglib/tbytevector.h>
#include <taglib/tpropertymap.h>
#include <taglib/xiphcomment.h>

#include <cctype>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#endif

namespace {

#ifdef _WIN32
std::wstring utf8ToWide(const char *path) {
    if (!path)
        return {};
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, nullptr, 0);
    if (length <= 0)
        return {};
    std::wstring result(static_cast<size_t>(length), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, result.data(), length) <= 0)
        return {};
    result.resize(static_cast<size_t>(length - 1));
    return result;
}
#endif

struct Utf8FileRef {
#ifdef _WIN32
    std::wstring wide_path;
    TagLib::FileRef file;
    explicit Utf8FileRef(const char *path)
        : wide_path(utf8ToWide(path)), file(wide_path.c_str()) {}
#else
    TagLib::FileRef file;
    explicit Utf8FileRef(const char *path) : file(path) {}
#endif
};

struct CoverData {
    std::vector<unsigned char> bytes;
    std::string mime;
};

bool fillFromVector(const TagLib::ByteVector &data, const std::string &mime, CoverData &out) {
    if (data.isEmpty())
        return false;
    out.bytes.assign(data.begin(), data.end());
    out.mime = mime;
    return true;
}

// Xiph-style picture lists (FLAC, Ogg Vorbis, Opus). Prefer a front cover.
bool xiphPicture(const TagLib::List<TagLib::FLAC::Picture *> &pics, CoverData &out) {
    TagLib::FLAC::Picture *fallback = nullptr;
    for (auto *pic : pics) {
        if (!pic || pic->data().isEmpty())
            continue;
        if (pic->type() == TagLib::FLAC::Picture::FrontCover)
            return fillFromVector(pic->data(), pic->mimeType().to8Bit(true), out);
        if (!fallback)
            fallback = pic;
    }
    if (fallback)
        return fillFromVector(fallback->data(), fallback->mimeType().to8Bit(true), out);
    return false;
}

bool embeddedCover(TagLib::FileRef &f, CoverData &out) {
    if (f.isNull() || !f.file())
        return false;

    if (auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(f.file())) {
        if (auto *tag = mpeg->ID3v2Tag()) {
            auto frames = tag->frameListMap()["APIC"];
            for (auto *frame : frames) {
                auto *pic = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(frame);
                if (!pic || pic->picture().isEmpty())
                    continue;
                return fillFromVector(pic->picture(), pic->mimeType().to8Bit(true), out);
            }
        }
    } else if (auto *flac = dynamic_cast<TagLib::FLAC::File *>(f.file())) {
        return xiphPicture(flac->pictureList(), out);
    } else if (auto *mp4 = dynamic_cast<TagLib::MP4::File *>(f.file())) {
        if (mp4->tag() && mp4->tag()->itemMap().contains("covr")) {
            auto list = mp4->tag()->itemMap()["covr"].toCoverArtList();
            if (!list.isEmpty()) {
                auto cover = list.front();
                std::string mime = "image/jpeg";
                switch (cover.format()) {
                    case TagLib::MP4::CoverArt::PNG:
                        mime = "image/png";
                        break;
                    case TagLib::MP4::CoverArt::BMP:
                        mime = "image/bmp";
                        break;
                    case TagLib::MP4::CoverArt::GIF:
                        mime = "image/gif";
                        break;
                    default:
                        break;
                }
                return fillFromVector(cover.data(), mime, out);
            }
        }
    } else if (auto *vorbis = dynamic_cast<TagLib::Ogg::Vorbis::File *>(f.file())) {
        if (vorbis->tag())
            return xiphPicture(vorbis->tag()->pictureList(), out);
    } else if (auto *opus = dynamic_cast<TagLib::Ogg::Opus::File *>(f.file())) {
        if (opus->tag())
            return xiphPicture(opus->tag()->pictureList(), out);
    }
    return false;
}

// Folder-cover fallback: look for cover/folder/front/album(art)(small).{jpg,jpeg,png,bmp,gif}
// in the file's directory (case-insensitive), then one level up (multi-disc
// layouts like `Album/Disc 1/track.flac` often keep `Album/cover.jpg`), like
// the C++ original.
bool folderCover(const std::string &path, CoverData &out) {
    const std::vector<std::string> names = {"cover", "folder", "front", "album", "albumart", "albumartsmall"};
    const std::vector<std::string> exts = {".jpg", ".jpeg", ".png", ".bmp", ".gif"};

#ifdef _WIN32
    std::filesystem::path dir = std::filesystem::u8path(path).parent_path();
#else
    std::filesystem::path dir = std::filesystem::path(path).parent_path();
#endif
    std::vector<std::filesystem::path> dirs;
    dirs.push_back(dir);
    if (!dir.parent_path().empty())
        dirs.push_back(dir.parent_path());

    for (const auto &current : dirs) {
        std::vector<std::filesystem::directory_entry> candidates;
        std::error_code ec;
        for (const auto &entry : std::filesystem::directory_iterator(current, ec)) {
            if (ec)
                break;
            if (entry.is_directory(ec))
                continue;
            std::string stem = entry.path().stem().string();
            std::string ext = entry.path().extension().string();
            for (auto &ch : stem)
                ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
            for (auto &ch : ext)
                ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
            for (const auto &name : names) {
                if (stem != name)
                    continue;
                for (const auto &e : exts) {
                    if (ext == e)
                        candidates.push_back(entry);
                }
            }
        }
        if (candidates.empty())
            continue;
        // Prefer jpg/png covers in name order; take the first candidate.
        auto &entry = candidates.front();
        std::ifstream in(entry.path(), std::ios::binary);
        if (!in)
            continue;
        std::string data((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        if (data.empty())
            continue;
        std::string ext = entry.path().extension().string();
        std::string mime = "image/jpeg";
        for (auto &ch : ext)
            ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
        if (ext == ".png")
            mime = "image/png";
        else if (ext == ".gif")
            mime = "image/gif";
        else if (ext == ".bmp")
            mime = "image/bmp";
        out.bytes.assign(data.begin(), data.end());
        out.mime = mime;
        return true;
    }
    return false;
}

std::string normalizedKey(const TagLib::String &key) {
    std::string value = key.to8Bit(true);
    std::string out;
    for (unsigned char c : value)
        if (std::isalnum(c))
            out.push_back(static_cast<char>(std::toupper(c)));
    return out;
}

bool propertyNumber(const TagLib::PropertyMap &properties, const char *wanted, double &out) {
    for (auto it = properties.begin(); it != properties.end(); ++it) {
        if (normalizedKey(it->first) != wanted || it->second.isEmpty())
            continue;
        std::string value = it->second.front().to8Bit(true);
        char *end = nullptr;
        const double parsed = std::strtod(value.c_str(), &end);
        if (end == value.c_str() || !std::isfinite(parsed))
            return false;
        // ReplayGain gain tags conventionally include the dB suffix.
        while (*end && std::isspace(static_cast<unsigned char>(*end))) ++end;
        if (*end && std::string(end) != "dB" && std::string(end) != "DB")
            return false;
        out = parsed;
        return true;
    }
    return false;
}

char *dupStr(const std::string &s) {
    char *p = static_cast<char *>(std::malloc(s.size() + 1));
    if (!p)
        return nullptr;
    std::memcpy(p, s.c_str(), s.size() + 1);
    return p;
}

} // namespace

extern "C" {

int forte_extract_cover(const char *path,
                        unsigned char **out_data, size_t *out_size,
                        char **out_mime) {
    if (!path || !out_data || !out_size || !out_mime)
        return 0;
    *out_data = nullptr;
    *out_size = 0;
    *out_mime = nullptr;

    CoverData cover;
    bool found = false;
    {
        Utf8FileRef f(path);
        found = embeddedCover(f.file, cover);
    }
    if (!found)
        found = folderCover(path, cover);
    if (!found || cover.bytes.empty())
        return 0;

    unsigned char *data = static_cast<unsigned char *>(std::malloc(cover.bytes.size()));
    if (!data)
        return 0;
    std::memcpy(data, cover.bytes.data(), cover.bytes.size());
    char *mime = dupStr(cover.mime);
    if (!mime) {
        std::free(data);
        return 0;
    }
    *out_data = data;
    *out_size = cover.bytes.size();
    *out_mime = mime;
    return 1;
}

void forte_free_cover(unsigned char *data, char *mime) {
    std::free(data);
    std::free(mime);
}

char *forte_extract_album_artist(const char *path) {
    if (!path)
        return nullptr;
    Utf8FileRef f(path);
    if (f.file.isNull() || !f.file.file())
        return nullptr;
    const TagLib::PropertyMap properties = f.file.file()->properties();
    const TagLib::StringList values = properties[TagLib::String("ALBUMARTIST")];
    if (values.isEmpty() || values.front().isEmpty())
        return nullptr;
    return dupStr(values.front().to8Bit(true));
}

int forte_extract_replaygain(const char *path, double *track_gain, int *has_track_gain,
                             double *track_peak, int *has_track_peak,
                             double *album_gain, int *has_album_gain,
                             double *album_peak, int *has_album_peak) {
    if (!path || !track_gain || !has_track_gain || !track_peak || !has_track_peak ||
        !album_gain || !has_album_gain || !album_peak || !has_album_peak)
        return 0;
    *has_track_gain = *has_track_peak = *has_album_gain = *has_album_peak = 0;
    Utf8FileRef f(path);
    if (f.file.isNull() || !f.file.file()) return 0;
    const TagLib::PropertyMap properties = f.file.file()->properties();
    *has_track_gain = propertyNumber(properties, "REPLAYGAINTRACKGAIN", *track_gain);
    *has_track_peak = propertyNumber(properties, "REPLAYGAINTRACKPEAK", *track_peak);
    *has_album_gain = propertyNumber(properties, "REPLAYGAINALBUMGAIN", *album_gain);
    *has_album_peak = propertyNumber(properties, "REPLAYGAINALBUMPEAK", *album_peak);
    return 1;
}

unsigned int forte_extract_disc_number(const char *path) {
    if (!path)
        return 1;
    Utf8FileRef f(path);
    if (f.file.isNull() || !f.file.file())
        return 1;
    const TagLib::PropertyMap properties = f.file.file()->properties();
    const TagLib::StringList values = properties[TagLib::String("DISCNUMBER")];
    if (values.isEmpty() || values.front().isEmpty())
        return 1;
    bool ok = false;
    const unsigned int disc = values.front().toInt(&ok);
    return ok && disc > 0 ? disc : 1;
}

void forte_free_string(char *value) {
    std::free(value);
}

int forte_write_metadata(const char *path,
                         const char *title, const char *artist,
                         const char *album, const char *genre,
                         const char *comment, unsigned int year,
                         unsigned int track, unsigned int disc,
                         char *error, size_t error_size) {
    auto report = [error, error_size](const char *message) {
        if (!error || error_size == 0)
            return;
        std::strncpy(error, message, error_size - 1);
        error[error_size - 1] = '\0';
    };
    if (!path) {
        report("missing audio path");
        return 0;
    }

    Utf8FileRef f(path);
    if (f.file.isNull() || !f.file.file() || !f.file.tag()) {
        report("TagLib could not open the audio file");
        return 0;
    }
    auto *tag = f.file.tag();
    tag->setTitle(TagLib::String(title ? title : "", TagLib::String::UTF8));
    tag->setArtist(TagLib::String(artist ? artist : "", TagLib::String::UTF8));
    tag->setAlbum(TagLib::String(album ? album : "", TagLib::String::UTF8));
    tag->setGenre(TagLib::String(genre ? genre : "", TagLib::String::UTF8));
    tag->setComment(TagLib::String(comment ? comment : "", TagLib::String::UTF8));
    tag->setYear(year);
    tag->setTrack(track);

    // DISCNUMBER is not part of TagLib::Tag's portable basic fields. Use the
    // property map when the format supports it (FLAC/Ogg/Opus and newer MP4/
    // ID3 backends); failure to expose it must not prevent the common fields
    // from being saved.
    if (disc > 0) {
        TagLib::PropertyMap properties = f.file.file()->properties();
        properties.replace("DISCNUMBER", TagLib::StringList(TagLib::String::number(disc)));
        f.file.file()->setProperties(properties);
    }

    if (!f.file.save()) {
        report("TagLib failed to save the audio file");
        return 0;
    }
    report("");
    return 1;
}

} // extern "C"
