// AFL file-input harness for pbrt-v4's untrusted-input readers.
//
// pbrt rejects malformed input with ErrorExit() -> std::quick_exit(1)
// (src/pbrt/util/error.cpp), so these are fork-per-input (AFL, afl: true)
// targets with a main() that reads one input file, not libFuzzer targets.
// The reader is chosen at compile time with -DPBRT_FUZZ_<MODE>.
// Image::Read dispatches on the file extension, so the image mode is built
// once per format with -DPBRT_FUZZ_EXT=".exr" (etc.) and reads a private
// copy of the input named with that suffix: the decoder a target fuzzes
// does not depend on the name Mayhem gives the input file.
#include <pbrt/pbrt.h>
#include <pbrt/options.h>
#include <pbrt/parser.h>
#include <pbrt/scene.h>
#include <pbrt/bxdfs.h>
#include <pbrt/util/image.h>
#include <pbrt/util/mesh.h>
#include <pbrt/util/spectrum.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <unistd.h>
#include <vector>

using namespace pbrt;

#if defined(PBRT_FUZZ_IMAGE)
// Sanitizer runtime hook (weak: absent when built without sanitizers).
extern "C" void __sanitizer_set_death_callback(void (*)(void)) __attribute__((weak));

static std::string g_tmpCopy;
static void RemoveTmpCopy() {
    if (!g_tmpCopy.empty())
        unlink(g_tmpCopy.c_str());
}

// Copy `src` to a fresh $TMPDIR file ending in PBRT_FUZZ_EXT. ErrorExit()
// calls std::quick_exit(), so the copy is removed from an at_quick_exit
// handler as well as at normal exit, and from the sanitizer death callback
// when an input crashes (ASan/UBSan report, SEGV).
static std::string CopyWithExtension(const std::string &src) {
    std::ifstream in(src, std::ios::binary);
    if (!in) {
        perror(src.c_str());
        exit(2);
    }
    std::string bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    const char *dir = getenv("TMPDIR");
    std::string tmpl = std::string(dir && *dir ? dir : "/tmp") + "/pbrt-fuzz-XXXXXX" +
                       PBRT_FUZZ_EXT;
    std::vector<char> name(tmpl.begin(), tmpl.end());
    name.push_back('\0');
    int fd = mkstemps(name.data(), (int)strlen(PBRT_FUZZ_EXT));
    if (fd < 0) {
        perror("mkstemps");
        exit(2);
    }
    g_tmpCopy = name.data();
    atexit(RemoveTmpCopy);
    at_quick_exit(RemoveTmpCopy);
    if (__sanitizer_set_death_callback)
        __sanitizer_set_death_callback(RemoveTmpCopy);
    size_t off = 0;
    while (off < bytes.size()) {
        ssize_t n = write(fd, bytes.data() + off, bytes.size() - off);
        if (n <= 0) {
            perror("write");
            exit(2);
        }
        off += (size_t)n;
    }
    close(fd);
    return g_tmpCopy;
}
#endif

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <input file>\n", argv[0]);
        return 2;
    }
    std::string filename = argv[1];

    PBRTOptions opt;
    opt.nThreads = 1;
    opt.quiet = true;
    InitPBRT(opt);

#if defined(PBRT_FUZZ_FORMAT)
    // pbrt --format / --upgrade: tokenizer, directive parser, parameter
    // lists and the upgrade rewrites, printed back as scene text.
    FormattingParserTarget target(/*toPly=*/false, /*upgrade=*/true);
    std::vector<std::string> files{filename};
    ParseFiles(&target, files);
#elif defined(PBRT_FUZZ_SCENE)
    // pbrt <scene> up to (not including) the render: BasicSceneBuilder,
    // typed parameter lookups, then the media/textures/lights/materials
    // that RenderCPU() creates first (RGB->spectrum conversion lives here).
    BasicScene scene;
    BasicSceneBuilder builder(&scene);
    std::vector<std::string> files{filename};
    ParseFiles(&builder, files);
    std::map<std::string, Medium> media = scene.CreateMedia();
    NamedTextures textures = scene.CreateTextures();
    std::map<int, pstd::vector<Light> *> shapeIndexToAreaLights;
    std::vector<Light> lights = scene.CreateLights(textures, &shapeIndexToAreaLights);
    std::map<std::string, Material> namedMaterials;
    std::vector<Material> materials;
    scene.CreateMaterials(textures, &namedMaterials, &materials);
    // Shapes (trianglemesh/bilinearmesh index checks, plymesh, curves,
    // loopsubdiv, ...) and the BVH over them, as RenderCPU() does next.
    Primitive accel = scene.CreateAggregate(textures, shapeIndexToAreaLights, media,
                                            namedMaterials, materials);
    printf("lights %zu materials %zu media %zu aggregate %s\n", lights.size(),
           materials.size(), media.size(), accel ? "yes" : "no");
#elif defined(PBRT_FUZZ_IMAGE)
    // Image::Read dispatches on the extension: .pfm .hdr .qoi .png .exr,
    // anything else (here .tga) falls back to stb_image.
#ifndef PBRT_FUZZ_EXT
#error "image mode needs -DPBRT_FUZZ_EXT=\".<ext>\""
#endif
    ImageAndMetadata im = Image::Read(CopyWithExtension(filename));
    const Image &image = im.image;
    Point2i res = image.Resolution();
    printf("%d x %d, %d channels\n", res.x, res.y, image.NChannels());
    if (res.x > 0 && res.y > 0 && image.NChannels() > 0) {
        ImageChannelValues avg = image.Average(image.AllChannelsDesc());
        printf("avg[0] %f\n", (double)avg[0]);
    }
#elif defined(PBRT_FUZZ_PLY)
    // plymesh shape / plytool: rply + index validation + triangulation.
    TriQuadMesh mesh = TriQuadMesh::ReadPLY(filename);
    mesh.ConvertToOnlyTriangles();
    mesh.ComputeNormals();
    printf("%zu vertices %zu triangle indices\n", mesh.p.size(), mesh.triIndices.size());
#elif defined(PBRT_FUZZ_SPECTRUM)
    // "spectrum" parameters naming a file: ReadFloatFile + wavelength checks.
    pstd::optional<Spectrum> s = PiecewiseLinearSpectrum::Read(filename, Allocator());
    if (s)
        printf("max %f\n", (double)s->MaxValue());
#elif defined(PBRT_FUZZ_BSDF)
    // "measured" material: the .bsdf tensor file reader.
    MeasuredBxDFData *data = MeasuredBxDF::BRDFDataFromFile(filename, Allocator());
    printf("bsdf %s\n", data ? "ok" : "null");
#else
#error "define one PBRT_FUZZ_<MODE>"
#endif
    return 0;
}
