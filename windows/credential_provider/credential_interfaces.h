#pragma once
#include <credentialprovider.h>

namespace ligament {
// Windows PNG-buffer extension; absent from public Windows SDK headers.
// ABI reference, pinned primary implementation:
// github.com/lithnet/windows-credential-provider/tree/5e216f42a4e99b0408fbd6e9d439b16cc2b3690e/src/Lithnet.CredentialProvider/Interop/Interfaces
MIDL_INTERFACE("64A5010E-4363-41F8-9738-19045C20DABC")
ILigamentCredential3 : public ICredentialProviderCredential2 {
    virtual HRESULT STDMETHODCALLTYPE GetBitmapBufferValue(DWORD field, DWORD* size, BYTE** buffer) = 0;
};
MIDL_INTERFACE("2D8DEEB8-1322-4973-8DF9-B282F2468290")
ILigamentCredentialEvents3 : public ICredentialProviderCredentialEvents2 {
    virtual HRESULT STDMETHODCALLTYPE SetFieldBitmapBuffer(ICredentialProviderCredential* credential,
        DWORD field, DWORD size, BYTE* buffer) = 0;
};
}
