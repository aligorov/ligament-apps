#pragma once
#include <windows.h>
#include <credentialprovider.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <cstring>

namespace ligament {
// Windows' PNG-buffer extension is absent from public SDK headers. ABI verified
// against Lithnet.CredentialProvider/Interop/Interfaces (Credential3/Events3).
MIDL_INTERFACE("64A5010E-4363-41F8-9738-19045C20DABC")
ILigamentCredential3 : public ICredentialProviderCredential2 {
    virtual HRESULT STDMETHODCALLTYPE GetBitmapBufferValue(DWORD field, DWORD* size, BYTE** buffer) = 0;
};
MIDL_INTERFACE("2D8DEEB8-1322-4973-8DF9-B282F2468290")
ILigamentCredentialEvents3 : public ICredentialProviderCredentialEvents2 {
    virtual HRESULT STDMETHODCALLTYPE SetFieldBitmapBuffer(ICredentialProviderCredential* credential,
        DWORD field, DWORD size, BYTE* buffer) = 0;
};

// Caller owns the CoTaskMem allocation. WIC interprets the source as PBGRA;
// premultiplied antialiased edges are converted to straight BGRA for PNG.
inline HRESULT EncodeCredentialBitmap(HBITMAP bitmap, DWORD* size, BYTE** buffer) {
    if (!size || !buffer) return E_POINTER;
    *size = 0;
    *buffer = nullptr;
    DIBSECTION dib = {};
    if (!bitmap || GetObject(bitmap, sizeof(dib), &dib) != sizeof(dib) ||
        !dib.dsBm.bmBits || dib.dsBm.bmBitsPixel != 32 || dib.dsBmih.biHeight >= 0)
        return E_INVALIDARG;
    using Microsoft::WRL::ComPtr;
    ComPtr<IWICImagingFactory> factory;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(factory.GetAddressOf()));
    if (FAILED(hr)) return hr;
    ComPtr<IWICBitmap> source;
    hr = factory->CreateBitmapFromMemory(dib.dsBm.bmWidth, dib.dsBm.bmHeight,
        GUID_WICPixelFormat32bppPBGRA, dib.dsBm.bmWidthBytes,
        dib.dsBm.bmWidthBytes * dib.dsBm.bmHeight,
        static_cast<BYTE*>(dib.dsBm.bmBits), &source);
    if (FAILED(hr)) return hr;
    ComPtr<IWICFormatConverter> converted;
    hr = factory->CreateFormatConverter(&converted);
    if (FAILED(hr)) return hr;
    hr = converted->Initialize(source.Get(), GUID_WICPixelFormat32bppBGRA,
        WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom);
    if (FAILED(hr)) return hr;
    ComPtr<IStream> stream;
    hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
    if (FAILED(hr)) return hr;
    ComPtr<IWICBitmapEncoder> encoder;
    hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
    if (FAILED(hr)) return hr;
    hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
    if (FAILED(hr)) return hr;
    ComPtr<IWICBitmapFrameEncode> frame;
    hr = encoder->CreateNewFrame(&frame, nullptr);
    if (FAILED(hr)) return hr;
    hr = frame->Initialize(nullptr);
    if (FAILED(hr)) return hr;
    hr = frame->SetSize(dib.dsBm.bmWidth, dib.dsBm.bmHeight);
    if (FAILED(hr)) return hr;
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    hr = frame->SetPixelFormat(&format);
    if (FAILED(hr)) return hr;
    if (!IsEqualGUID(format, GUID_WICPixelFormat32bppBGRA)) return E_FAIL;
    hr = frame->WriteSource(converted.Get(), nullptr);
    if (FAILED(hr)) return hr;
    hr = frame->Commit();
    if (FAILED(hr)) return hr;
    hr = encoder->Commit();
    if (FAILED(hr)) return hr;
    STATSTG stat = {};
    hr = stream->Stat(&stat, STATFLAG_NONAME);
    if (FAILED(hr)) return hr;
    if (stat.cbSize.HighPart || !stat.cbSize.LowPart) return E_FAIL;
    HGLOBAL memory = nullptr;
    hr = GetHGlobalFromStream(stream.Get(), &memory);
    if (FAILED(hr)) return hr;
    void* data = GlobalLock(memory);
    if (!data) return E_FAIL;
    BYTE* result = static_cast<BYTE*>(CoTaskMemAlloc(stat.cbSize.LowPart));
    if (result) std::memcpy(result, data, stat.cbSize.LowPart);
    GlobalUnlock(memory);
    if (!result) return E_OUTOFMEMORY;
    *size = stat.cbSize.LowPart;
    *buffer = result;
    return S_OK;
}
}
