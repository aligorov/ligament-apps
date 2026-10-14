// Exercises the actual credential object and both image transports. This does
// not replace a visual check in LogonUI: that requires an interactive Windows VM.
#include "../credential_provider/LigamentCredential.h"
#include "../credential_provider/app_logo_data.h"
#include "../credential_provider/qrcodegen.hpp"
#include <wincodec.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace ligament {
LONG g_cRefDll = 0;

// Enabled by the test target only; no test exports or registry changes.
class CredentialImageTestAccess {
public:
    static void InstallQr(LigamentCredential& credential, const char* text) {
        HBITMAP bitmap = credential.CreateQrBitmap(text, 256);
        if (!bitmap) { std::fprintf(stderr, "actual QR constructor failed\n"); std::exit(1); }
        EnterCriticalSection(&credential.m_csPoll);
        if (credential.m_hQrBmp) DeleteObject(credential.m_hQrBmp);
        credential.m_hQrBmp = bitmap;
        LeaveCriticalSection(&credential.m_csPoll);
    }
    static void ClearQr(LigamentCredential& credential) { credential.ClearQrBitmap(); }
};
}

using Microsoft::WRL::ComPtr;
using namespace ligament;

static void Check(bool ok, const char* message) {
    if (!ok) { std::fprintf(stderr, "%s\n", message); std::exit(1); }
}

struct Pixels {
    UINT width = 0;
    UINT height = 0;
    std::vector<BYTE> bgra;
};

static Pixels DecodePng(const std::vector<BYTE>& png) {
    const BYTE signature[] = {137,80,78,71,13,10,26,10};
    Check(png.size() > sizeof(signature) && !std::memcmp(png.data(), signature, sizeof(signature)),
        "credential buffer must contain a PNG");
    ComPtr<IWICImagingFactory> factory;
    Check(SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(factory.GetAddressOf()))), "WIC factory");
    ComPtr<IWICStream> stream;
    Check(SUCCEEDED(factory->CreateStream(&stream)), "WIC stream");
    Check(SUCCEEDED(stream->InitializeFromMemory(const_cast<BYTE*>(png.data()),
        static_cast<DWORD>(png.size()))), "WIC PNG memory");
    ComPtr<IWICBitmapDecoder> decoder;
    Check(SUCCEEDED(factory->CreateDecoderFromStream(stream.Get(), nullptr,
        WICDecodeMetadataCacheOnLoad, &decoder)), "credential PNG decode");
    ComPtr<IWICBitmapFrameDecode> frame;
    Check(SUCCEEDED(decoder->GetFrame(0, &frame)), "PNG frame");
    Pixels result;
    Check(SUCCEEDED(frame->GetSize(&result.width, &result.height)), "PNG dimensions");
    Check(result.width == 256 && result.height == 256, "actual credential image size");
    ComPtr<IWICFormatConverter> converter;
    Check(SUCCEEDED(factory->CreateFormatConverter(&converter)), "WIC converter");
    Check(SUCCEEDED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
        WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom)), "BGRA decode");
    result.bgra.resize(static_cast<size_t>(result.width) * result.height * 4);
    Check(SUCCEEDED(converter->CopyPixels(nullptr, result.width * 4,
        static_cast<UINT>(result.bgra.size()), result.bgra.data())), "PNG pixels");
    return result;
}

static std::vector<BYTE> GetPng(ILigamentCredential3* credential) {
    DWORD size = 0;
    BYTE* buffer = nullptr;
    Check(SUCCEEDED(credential->GetBitmapBufferValue(FID_LOGO, &size, &buffer)) && size && buffer,
        "actual credential GetBitmapBufferValue");
    std::vector<BYTE> result(buffer, buffer + size);
    CoTaskMemFree(buffer);
    return result;
}

static Pixels GetLegacyBitmap(ICredentialProviderCredential* credential) {
    HBITMAP bitmap = nullptr;
    Check(SUCCEEDED(credential->GetBitmapValue(FID_LOGO, &bitmap)) && bitmap,
        "legacy GetBitmapValue must remain available");
    BITMAP descriptor = {};
    Check(GetObject(bitmap, sizeof(descriptor), &descriptor) == sizeof(descriptor), "bitmap dimensions");
    Check(descriptor.bmWidth == 256 && descriptor.bmHeight == 256, "legacy credential image size");
    BITMAPINFO info = {};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = descriptor.bmWidth;
    info.bmiHeader.biHeight = -descriptor.bmHeight;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    Pixels result;
    result.width = result.height = 256;
    result.bgra.resize(256 * 256 * 4);
    HDC dc = GetDC(nullptr);
    const int rows = GetDIBits(dc, bitmap, 0, 256, result.bgra.data(), &info, DIB_RGB_COLORS);
    ReleaseDC(nullptr, dc);
    DeleteObject(bitmap);
    Check(rows == 256, "read actual HBITMAP in display orientation");
    return result;
}

static void WritePng(const char* name, const std::vector<BYTE>& png) {
    FILE* file = nullptr;
    Check(fopen_s(&file, name, "wb") == 0 && file, "open image artifact");
    Check(std::fwrite(png.data(), 1, png.size(), file) == png.size(), "write image artifact");
    Check(std::fclose(file) == 0, "close image artifact");
}

static void CheckLogo(const Pixels& image) {
    unsigned transparent = 0, opaque = 0, partial = 0;
    for (size_t i = 0; i < 256 * 256; ++i) {
        const unsigned alpha = c_AppLogoPixels[i] >> 24;
        Check(image.bgra[i * 4 + 3] == alpha, "actual logo alpha or orientation changed");
        if (!alpha) ++transparent;
        else if (alpha == 255) ++opaque;
        else ++partial;
        if (!alpha) continue;
        for (unsigned channel = 0; channel < 3; ++channel) {
            const int expected = (c_AppLogoPixels[i] >> (channel * 8)) & 255;
            const int premultiplied = (image.bgra[i * 4 + channel] * alpha + 127) / 255;
            Check(std::abs(premultiplied - expected) <= 2, "actual logo color or premultiplication changed");
        }
    }
    Check(transparent > 40000 && opaque > 10000 && partial > 0,
        "logo must keep transparent background and antialiased edges");
    std::printf("Actual logo: %u transparent, %u opaque, %u partial pixels\n", transparent, opaque, partial);
}

static void CheckQr(const Pixels& image, const char* text, bool checkAlpha) {
    const qrcodegen::QrCode qr = qrcodegen::QrCode::encodeText(text, qrcodegen::QrCode::Ecc::MEDIUM);
    const int size = qr.getSize();
    const int scale = std::max(1, 160 / size);
    const int start = (256 - size * scale) / 2;
    Check(start >= 4 * scale, "QR quiet zone must fit in the image");
    for (int y = -4 * scale; y < (size + 4) * scale; ++y) {
        for (int x = -4 * scale; x < (size + 4) * scale; ++x) {
            const int px = start + x, py = start + y;
            Check(px >= 0 && px < 256 && py >= 0 && py < 256, "QR image bounds");
            const size_t offset = (static_cast<size_t>(py) * 256 + px) * 4;
            const bool inModules = x >= 0 && y >= 0 && x < size * scale && y < size * scale;
            const bool dark = inModules && qr.getModule(x / scale, y / scale);
            if (dark) {
                Check(image.bgra[offset] == 0x1D && image.bgra[offset + 1] == 0x0F &&
                    image.bgra[offset + 2] == 0x0A, "QR module missing, mirrored or flipped");
            } else {
                Check(image.bgra[offset] == 255 && image.bgra[offset + 1] == 255 &&
                    image.bgra[offset + 2] == 255, "QR light module or quiet zone damaged");
            }
            if (checkAlpha) Check(image.bgra[offset + 3] == 255, "QR background must stay opaque");
        }
    }
    std::printf("Actual QR: %dx%d modules, scale=%d, upright, four-module quiet zone intact\n", size, size, scale);
}

int main() {
    Check(SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)), "COM initialization");
    {
        auto* actual = new LigamentCredential();
        ComPtr<ICredentialProviderCredential> base;
        base.Attach(actual);
        Config config;
        actual->Initialize(config, false, CPUS_LOGON);
        ComPtr<ILigamentCredential3> credential;
        Check(SUCCEEDED(base.As(&credential)), "actual Credential3 QueryInterface");
        ComPtr<ICredentialProviderCredential2> credential2;
        Check(SUCCEEDED(base.As(&credential2)), "actual Credential2 QueryInterface");
        PWSTR sid = reinterpret_cast<PWSTR>(1);
        Check(credential2->GetUserSid(&sid) == E_NOTIMPL && !sid,
            "generic credential must remain its own dedicated tile (not Other user)");
        Check(credential2->GetUserSid(nullptr) == E_POINTER, "null SID output");
        DWORD invalidSize = 123;
        BYTE* invalidBuffer = reinterpret_cast<BYTE*>(1);
        Check(FAILED(credential->GetBitmapBufferValue(FID_NUM_FIELDS, &invalidSize, &invalidBuffer)) &&
            !invalidSize && !invalidBuffer, "unsupported image field must clear outputs");
        Check(credential->GetBitmapBufferValue(FID_LOGO, nullptr, &invalidBuffer) == E_POINTER,
            "null image size output");
        Check(credential->GetBitmapBufferValue(FID_LOGO, &invalidSize, nullptr) == E_POINTER,
            "null image buffer output");

        const std::vector<BYTE> logo = GetPng(credential.Get());
        CheckLogo(DecodePng(logo));
        WritePng("credential-logo.png", logo);
        HBITMAP legacyLogo = nullptr;
        Check(SUCCEEDED(base->GetBitmapValue(FID_LOGO, &legacyLogo)) && legacyLogo,
            "legacy logo fallback remains available");
        DeleteObject(legacyLogo);

        const char* url = "https://login.ligament.test/passkey?id=regression-qr-01";
        CredentialImageTestAccess::InstallQr(*actual, url);
        const std::vector<BYTE> qr = GetPng(credential.Get());
        CheckQr(DecodePng(qr), url, true);
        CheckQr(GetLegacyBitmap(base.Get()), url, false);
        WritePng("credential-qr.png", qr);

        CredentialImageTestAccess::ClearQr(*actual);
        const std::vector<BYTE> restored = GetPng(credential.Get());
        CheckLogo(DecodePng(restored));
        Check(restored == logo, "clearing QR must restore original transparent logo");
    }
    Check(g_cRefDll == 0, "credential COM lifetime leaked");
    CoUninitialize();
    std::puts("Credential image regression tests passed (interactive LogonUI still requires VM verification)");
}
