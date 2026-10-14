#include "../credential_provider/credential_bitmap.h"
#include "../credential_provider/app_logo_data.h"
#include <cstdio>
#include <cstdlib>

static void Check(bool ok, const char* message) {
    if (!ok) { std::fprintf(stderr, "%s\n", message); std::exit(1); }
}
int main() {
    using Microsoft::WRL::ComPtr;
    Check(SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)), "COM init");
    {
        DWORD size = 123;
        BYTE* data = reinterpret_cast<BYTE*>(1);
        Check(ligament::EncodeCredentialBitmap(nullptr, &size, &data) == E_INVALIDARG &&
            !size && !data, "invalid bitmap must clear outputs");
        Check(ligament::EncodeCredentialBitmap(nullptr, nullptr, &data) == E_POINTER, "null output");
        BITMAPINFO info = {};
        info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        info.bmiHeader.biWidth = 256;
        info.bmiHeader.biHeight = -256;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        void* bits = nullptr;
        HBITMAP bitmap = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
        Check(bitmap && bits, "create bitmap");
        std::memcpy(bits, c_AppLogoPixels, sizeof(c_AppLogoPixels));
        HRESULT encode = ligament::EncodeCredentialBitmap(bitmap, &size, &data);
        if (FAILED(encode)) std::fprintf(stderr, "PNG encode HRESULT=0x%08lX\n", static_cast<unsigned long>(encode));
        Check(SUCCEEDED(encode), "encode PNG");
        DeleteObject(bitmap);
        const BYTE signature[] = {137,80,78,71,13,10,26,10};
        Check(size > 8 && !std::memcmp(data, signature, 8), "PNG signature");
        ComPtr<IWICImagingFactory> factory;
        Check(SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
            IID_PPV_ARGS(factory.GetAddressOf()))), "WIC factory");
        ComPtr<IWICStream> stream;
        Check(SUCCEEDED(factory->CreateStream(&stream)), "WIC stream");
        Check(SUCCEEDED(stream->InitializeFromMemory(data, size)), "stream data");
        ComPtr<IWICBitmapDecoder> decoder;
        Check(SUCCEEDED(factory->CreateDecoderFromStream(stream.Get(), nullptr,
            WICDecodeMetadataCacheOnLoad, &decoder)), "decode PNG");
        ComPtr<IWICBitmapFrameDecode> frame;
        Check(SUCCEEDED(decoder->GetFrame(0, &frame)), "PNG frame");
        ComPtr<IWICFormatConverter> converted;
        Check(SUCCEEDED(factory->CreateFormatConverter(&converted)), "converter");
        Check(SUCCEEDED(converted->Initialize(frame.Get(), GUID_WICPixelFormat32bppPBGRA,
            WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom)), "PBGRA conversion");
        BYTE pixels[256 * 256 * 4];
        Check(SUCCEEDED(converted->CopyPixels(nullptr, 256*4, sizeof(pixels), pixels)), "pixels");
        unsigned transparent = 0, opaque = 0, edges = 0;
        for (unsigned i = 0; i < 256*256; ++i) {
            unsigned alpha = c_AppLogoPixels[i] >> 24;
            Check(pixels[i*4+3] == alpha, "alpha lost in PNG roundtrip");
            if (!alpha) ++transparent;
            else if (alpha == 255) ++opaque;
            else ++edges;
        }
        Check(transparent > 40000 && opaque > 10000 && edges > 0, "logo transparency coverage");
        // Release readers before freeing their borrowed PNG buffer.
        converted.Reset(); frame.Reset(); decoder.Reset(); stream.Reset();
        CoTaskMemFree(data);
        std::printf("PNG roundtrip: %u transparent, %u opaque, %u antialiased pixels\n",
            transparent, opaque, edges);
    }
    CoUninitialize();
}
