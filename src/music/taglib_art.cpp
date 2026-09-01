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
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace {

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

    std::filesystem::path dir = std::filesystem::path(path).parent_path();
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
        TagLib::FileRef f(path);
        found = embeddedCover(f, cover);
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
    TagLib::FileRef f(path);
    if (f.isNull() || !f.file())
        return nullptr;
    const TagLib::PropertyMap properties = f.file()->properties();
    const TagLib::StringList values = properties[TagLib::String("ALBUMARTIST")];
    if (values.isEmpty() || values.front().isEmpty())
        return nullptr;
    return dupStr(values.front().to8Bit(true));
}

unsigned int forte_extract_disc_number(const char *path) {
    if (!path)
        return 1;
    TagLib::FileRef f(path);
    if (f.isNull() || !f.file())
        return 1;
    const TagLib::PropertyMap properties = f.file()->properties();
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

    TagLib::FileRef f(path);
    if (f.isNull() || !f.file() || !f.tag()) {
        report("TagLib could not open the audio file");
        return 0;
    }
    auto *tag = f.tag();
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
        TagLib::PropertyMap properties = f.file()->properties();
        properties.replace("DISCNUMBER", TagLib::StringList(TagLib::String::number(disc)));
        f.file()->setProperties(properties);
    }

    if (!f.save()) {
        report("TagLib failed to save the audio file");
        return 0;
    }
    report("");
    return 1;
}

} // extern "C"
