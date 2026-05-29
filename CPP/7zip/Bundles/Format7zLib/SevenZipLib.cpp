// SevenZipLib.cpp -- implementation of the flat C interface (Phase 1).
//
// This wrapper is linked together with the 7za object set (7z handler +
// built-in codecs). It drives the in-process COM objects (IInArchive) and
// exposes a simple C ABI. The COM GUIDs are defined in DllExports2.cpp
// (which includes MyInitGuid.h); this file only references them, so it must
// NOT include MyInitGuid.h.

#include "StdAfx.h"

#include "../../../Common/MyWindows.h"

#include "../../../Common/Defs.h"
#include "../../../Common/IntToString.h"
#include "../../../Common/MyCom.h"
#include "../../../Common/StringConvert.h"
#include "../../../Common/UTFConvert.h"

#include "../../../Windows/FileDir.h"
#include "../../../Windows/FileFind.h"
#include "../../../Windows/PropVariant.h"
#include "../../../Windows/PropVariantConv.h"
#include "../../../Windows/TimeUtils.h"

#include "../../Common/FileStreams.h"
#include "../../Common/StreamObjects.h"

#include "../../Archive/IArchive.h"
#include "../../IPassword.h"

#include "../../../../C/7zVersion.h"

#if defined(_WIN32)
#define SZ_BUILD_DLL
#endif
#include "SevenZipLib.h"

using namespace NWindows;
using namespace NFile;

// ---------------------------------------------------------------------------
// 7z format class id: {23170F69-40C1-278A-1000-000110070000}
// ---------------------------------------------------------------------------

// Defined directly (not via Z7_DEFINE_GUID/DEFINE_GUID) because this
// translation unit does not enable INITGUID -- without INITGUID those macros
// only *declare* the symbol. The interface IIDs come from DllExports2.o; this
// CLSID is private to the wrapper, so file-local linkage is enough.
static const GUID CLSID_Format_7z =
  { 0x23170F69, 0x40C1, 0x278A, { 0x10, 0x00, 0x00, 0x01, 0x10, 0x07, 0x00, 0x00 } };

// CreateObject is provided by DllExports2.cpp (linked into this library).
STDAPI CreateObject(const GUID *clsid, const GUID *iid, void **outObject);

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

static bool Utf8ToUString(const char *s, UString &dest)
{
  dest.Empty();
  if (!s || !*s)
    return true;
  return ConvertUTF8ToUnicode(AString(s), dest);
}

static void UStringToUtf8(const UString &s, AString &dest)
{
  ConvertUnicodeToUTF8(s, dest);
}

// FILETIME (100-ns ticks since 1601-01-01) -> Unix seconds.
static int64_t FileTimeToUnix(const FILETIME &ft)
{
  const UInt64 t = ((UInt64)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
  // 116444736000000000 = ticks between 1601-01-01 and 1970-01-01
  if (t < (UInt64)116444736000000000ULL)
    return 0;
  return (int64_t)((t - (UInt64)116444736000000000ULL) / 10000000ULL);
}

// ---------------------------------------------------------------------------
// stream bridges to user read/write callbacks
// ---------------------------------------------------------------------------

Z7_CLASS_IMP_COM_1(
  CCallbackOutStream
  , ISequentialOutStream
)
public:
  Sz_WriteFunc Func;
  void *Ctx;
  bool UserError;
  CCallbackOutStream() : Func(NULL), Ctx(NULL), UserError(false) {}
};

Z7_COM7F_IMF(CCallbackOutStream::Write(const void *data, UInt32 size, UInt32 *processedSize))
{
  UInt32 proc = 0;
  if (Func && size != 0)
  {
    if (Func(Ctx, data, size, &proc) != 0 || proc != size)
    {
      UserError = true;
      if (processedSize) *processedSize = proc;
      return E_FAIL;
    }
  }
  if (processedSize) *processedSize = proc;
  return S_OK;
}

Z7_CLASS_IMP_COM_1(
  CCallbackInStream
  , ISequentialInStream
)
public:
  Sz_ReadFunc Func;
  void *Ctx;
  bool UserError;
  CCallbackInStream() : Func(NULL), Ctx(NULL), UserError(false) {}
};

Z7_COM7F_IMF(CCallbackInStream::Read(void *data, UInt32 size, UInt32 *processedSize))
{
  UInt32 proc = 0;
  if (Func && size != 0)
  {
    if (Func(Ctx, data, size, &proc) != 0)
    {
      UserError = true;
      if (processedSize) *processedSize = proc;
      return E_FAIL;
    }
  }
  if (processedSize) *processedSize = proc;
  return S_OK;
}

// ---------------------------------------------------------------------------
// password-aware open callback
// ---------------------------------------------------------------------------

class CArcOpenCallback Z7_final:
  public IArchiveOpenCallback,
  public ICryptoGetTextPassword,
  public CMyUnknownImp
{
  Z7_IFACES_IMP_UNK_2(IArchiveOpenCallback, ICryptoGetTextPassword)
public:
  bool PasswordIsDefined;
  UString Password;
  CArcOpenCallback() : PasswordIsDefined(false) {}
};

Z7_COM7F_IMF(CArcOpenCallback::SetTotal(const UInt64 *, const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(CArcOpenCallback::SetCompleted(const UInt64 *, const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(CArcOpenCallback::CryptoGetTextPassword(BSTR *password))
{
  if (!PasswordIsDefined)
    return E_ABORT;
  return StringToBstr(Password, password);
}

// ---------------------------------------------------------------------------
// extract callback for a single item -> a preset output stream
// ---------------------------------------------------------------------------

class CArcExtractCallback Z7_final:
  public IArchiveExtractCallback,
  public ICryptoGetTextPassword,
  public CMyUnknownImp
{
  Z7_IFACES_IMP_UNK_2(IArchiveExtractCallback, ICryptoGetTextPassword)
  Z7_IFACE_COM7_IMP(IProgress)

public:
  UInt32 TargetIndex;
  CMyComPtr<ISequentialOutStream> OutStream; // preset destination
  Int32 OpResult;                            // NExtract::NOperationResult::*
  bool GotStream;

  bool PasswordIsDefined;
  UString Password;

  Sz_ProgressFunc Progress;
  void *ProgressCtx;
  UInt64 Total;
  bool Cancelled;

  CArcExtractCallback() :
      TargetIndex(0),
      OpResult(NArchive::NExtract::NOperationResult::kOK),
      GotStream(false),
      PasswordIsDefined(false),
      Progress(NULL), ProgressCtx(NULL), Total(0), Cancelled(false) {}
};

Z7_COM7F_IMF(CArcExtractCallback::SetTotal(UInt64 size))
{
  Total = size;
  return S_OK;
}
Z7_COM7F_IMF(CArcExtractCallback::SetCompleted(const UInt64 *completeValue))
{
  if (Progress && completeValue)
    if (Progress(ProgressCtx, *completeValue, Total) != 0)
    {
      Cancelled = true;
      return E_ABORT;
    }
  return S_OK;
}

Z7_COM7F_IMF(CArcExtractCallback::GetStream(UInt32 index,
    ISequentialOutStream **outStream, Int32 askExtractMode))
{
  *outStream = NULL;
  if (askExtractMode != NArchive::NExtract::NAskMode::kExtract)
    return S_OK;
  if (index != TargetIndex)
    return S_OK; // not the item we asked for; skip it
  if (OutStream)
  {
    GotStream = true;
    CMyComPtr<ISequentialOutStream> s = OutStream;
    *outStream = s.Detach();
  }
  return S_OK;
}

Z7_COM7F_IMF(CArcExtractCallback::PrepareOperation(Int32)) { return S_OK; }

Z7_COM7F_IMF(CArcExtractCallback::SetOperationResult(Int32 operationResult))
{
  OpResult = operationResult;
  return S_OK;
}

Z7_COM7F_IMF(CArcExtractCallback::CryptoGetTextPassword(BSTR *password))
{
  if (!PasswordIsDefined)
    return E_ABORT;
  return StringToBstr(Password, password);
}

// ---------------------------------------------------------------------------
// archive handle
// ---------------------------------------------------------------------------

struct CSzArchive
{
  CMyComPtr<IInArchive> Archive;
  bool PasswordIsDefined;
  UString Password;
  Sz_ProgressFunc Progress;
  void *ProgressCtx;
  CSzArchive() : PasswordIsDefined(false), Progress(NULL), ProgressCtx(NULL) {}
};

static HRESULT GetProp(IInArchive *arc, UInt32 index, PROPID id, NCOM::CPropVariant &prop)
{
  return arc->GetProperty(index, id, &prop);
}

// Maps an NExtract operation result to an SZ_* error code.
static int OpResultToSz(Int32 r)
{
  switch (r)
  {
    case NArchive::NExtract::NOperationResult::kOK:
      return SZA_OK;
    case NArchive::NExtract::NOperationResult::kUnsupportedMethod:
      return SZA_ERR_EXTRACT;
    case NArchive::NExtract::NOperationResult::kCRCError:
    case NArchive::NExtract::NOperationResult::kDataError:
    case NArchive::NExtract::NOperationResult::kUnavailable:
    case NArchive::NExtract::NOperationResult::kUnexpectedEnd:
    case NArchive::NExtract::NOperationResult::kHeadersError:
      return SZA_ERR_EXTRACT;
    default:
      return SZA_ERR_EXTRACT;
  }
}

// Reads the uncompressed size of an item (0 if undefined).
static bool GetItemSize(IInArchive *arc, UInt32 index, UInt64 &size)
{
  size = 0;
  NCOM::CPropVariant prop;
  if (GetProp(arc, index, kpidSize, prop) != S_OK)
    return false;
  return ConvertPropVariantToUInt64(prop, size);
}

static bool GetItemIsDir(IInArchive *arc, UInt32 index, bool &isDir)
{
  isDir = false;
  NCOM::CPropVariant prop;
  if (GetProp(arc, index, kpidIsDir, prop) != S_OK)
    return false;
  if (prop.vt == VT_BOOL)
    isDir = VARIANT_BOOLToBool(prop.boolVal);
  else if (prop.vt != VT_EMPTY)
    return false;
  return true;
}

// ---------------------------------------------------------------------------
// archive writer (Phase 2)
// ---------------------------------------------------------------------------

struct CSzItem
{
  UString Name;     // path inside the archive
  bool FromFile;    // content from FilePath
  bool FromStream;  // content from a user read callback
  bool IsDir;
  UInt64 Size;

  // file source
  FString FilePath;
  NFile::NFind::CFileInfo Fi;

  // buffer source (when !FromFile && !FromStream)
  CByteBuffer Buf;

  // stream source
  Sz_ReadFunc ReadFunc;
  void *ReadCtx;

  bool MTimeDefined;
  UInt32 MTimeUnix;

  CSzItem() : FromFile(false), FromStream(false), IsDir(false), Size(0),
              ReadFunc(NULL), ReadCtx(NULL), MTimeDefined(false), MTimeUnix(0) {}
};

struct CSzWriter
{
  FString ArcPath;
  int Level;
  bool PasswordIsDefined;
  UString Password;
  Sz_ProgressFunc Progress;
  void *ProgressCtx;
  CObjectVector<CSzItem> Items;
  CSzWriter() : Level(5), PasswordIsDefined(false), Progress(NULL), ProgressCtx(NULL) {}
};

class CArcUpdateCallback Z7_final:
  public IArchiveUpdateCallback2,
  public ICryptoGetTextPassword2,
  public CMyUnknownImp
{
  Z7_IFACES_IMP_UNK_2(IArchiveUpdateCallback2, ICryptoGetTextPassword2)
  Z7_IFACE_COM7_IMP(IProgress)
  Z7_IFACE_COM7_IMP(IArchiveUpdateCallback)

public:
  const CObjectVector<CSzItem> *Items;
  bool PasswordIsDefined;
  UString Password;
  bool Failed;        // a source file could not be opened

  Sz_ProgressFunc Progress;
  void *ProgressCtx;
  UInt64 Total;
  bool Cancelled;

  CArcUpdateCallback() : Items(NULL), PasswordIsDefined(false), Failed(false),
                         Progress(NULL), ProgressCtx(NULL), Total(0), Cancelled(false) {}
};

Z7_COM7F_IMF(CArcUpdateCallback::SetTotal(UInt64 size))
{
  Total = size;
  return S_OK;
}
Z7_COM7F_IMF(CArcUpdateCallback::SetCompleted(const UInt64 *completeValue))
{
  if (Progress && completeValue)
    if (Progress(ProgressCtx, *completeValue, Total) != 0)
    {
      Cancelled = true;
      return E_ABORT;
    }
  return S_OK;
}

Z7_COM7F_IMF(CArcUpdateCallback::GetUpdateItemInfo(UInt32 /* index */,
    Int32 *newData, Int32 *newProperties, UInt32 *indexInArchive))
{
  if (newData) *newData = 1;
  if (newProperties) *newProperties = 1;
  if (indexInArchive) *indexInArchive = (UInt32)(Int32)-1;
  return S_OK;
}

Z7_COM7F_IMF(CArcUpdateCallback::GetProperty(UInt32 index, PROPID propID, PROPVARIANT *value))
{
  NCOM::CPropVariant prop;
  const CSzItem &item = (*Items)[index];

  switch (propID)
  {
    case kpidIsAnti:  prop = false; break;
    case kpidPath:    prop = item.Name; break;
    case kpidIsDir:   prop = item.IsDir; break;
    case kpidSize:    if (!item.IsDir) prop = item.Size; break;
    case kpidAttrib:
      if (item.FromFile) prop = (UInt32)item.Fi.GetWinAttrib();
      break;
    case kpidPosixAttrib:
      if (item.FromFile) prop = (UInt32)item.Fi.GetPosixAttrib();
      break;
    case kpidMTime:
      if (item.FromFile)
        PropVariant_SetFrom_FiTime(prop, item.Fi.MTime);
      else if (item.MTimeDefined)
        PropVariant_SetFrom_UnixTime(prop, item.MTimeUnix);
      break;
    case kpidCTime:
      if (item.FromFile) PropVariant_SetFrom_FiTime(prop, item.Fi.CTime);
      break;
    case kpidATime:
      if (item.FromFile) PropVariant_SetFrom_FiTime(prop, item.Fi.ATime);
      break;
  }
  prop.Detach(value);
  return S_OK;
}

Z7_COM7F_IMF(CArcUpdateCallback::GetStream(UInt32 index, ISequentialInStream **inStream))
{
  *inStream = NULL;
  const CSzItem &item = (*Items)[index];
  if (item.IsDir)
    return S_OK;

  if (item.FromFile)
  {
    CInFileStream *spec = new CInFileStream;
    CMyComPtr<ISequentialInStream> s(spec);
    if (!spec->Open(item.FilePath))
    {
      Failed = true;
      return S_FALSE; // skip this file; reported as failure by FinishArchive
    }
    *inStream = s.Detach();
  }
  else if (item.FromStream)
  {
    CCallbackInStream *spec = new CCallbackInStream;
    CMyComPtr<ISequentialInStream> s(spec);
    spec->Func = item.ReadFunc;
    spec->Ctx = item.ReadCtx;
    *inStream = s.Detach();
  }
  else
  {
    CBufInStream *spec = new CBufInStream;
    CMyComPtr<ISequentialInStream> s(spec);
    spec->Init(item.Buf, item.Buf.Size());
    *inStream = s.Detach();
  }
  return S_OK;
}

Z7_COM7F_IMF(CArcUpdateCallback::SetOperationResult(Int32)) { return S_OK; }

Z7_COM7F_IMF(CArcUpdateCallback::GetVolumeSize(UInt32, UInt64 *)) { return S_FALSE; }
Z7_COM7F_IMF(CArcUpdateCallback::GetVolumeStream(UInt32, ISequentialOutStream **)) { return E_NOTIMPL; }

Z7_COM7F_IMF(CArcUpdateCallback::CryptoGetTextPassword2(Int32 *passwordIsDefined, BSTR *password))
{
  if (passwordIsDefined)
    *passwordIsDefined = PasswordIsDefined ? 1 : 0;
  return StringToBstr(Password, password);
}

// Splits a UTF-8 source path into its final path component (file name).
static UString BaseNameFromPath(const UString &path)
{
  const int slash = path.ReverseFind_PathSepar();
  if (slash >= 0)
    return path.Ptr((unsigned)(slash + 1));
  return path;
}

// ---------------------------------------------------------------------------
// exported API
// ---------------------------------------------------------------------------

extern "C" {

SZ_API int SZ_CALL Sz_GlobalInit(void)
{
  return SZA_OK;
}

SZ_API const char * SZ_CALL Sz_VersionString(void)
{
  return MY_VERSION;
}

SZ_API SzArchive SZ_CALL Sz_OpenFileEx(const char *utf8Path, const char *utf8Password, int *outErr)
{
  int err = SZA_OK;
  SzArchive result = NULL;

  if (!utf8Path || !*utf8Path)
  {
    if (outErr) *outErr = SZA_ERR_PARAM;
    return NULL;
  }

  UString uPath, uPassword;
  if (!Utf8ToUString(utf8Path, uPath) || !Utf8ToUString(utf8Password, uPassword))
  {
    if (outErr) *outErr = SZA_ERR_PARAM;
    return NULL;
  }

  CSzArchive *h = NULL;
  CMyComPtr<IInArchive> archive;
  if (CreateObject(&CLSID_Format_7z, &IID_IInArchive, (void **)&archive) != S_OK || !archive)
  {
    err = SZA_ERR_NOT_ARCHIVE;
    goto done;
  }

  {
    CInFileStream *fileSpec = new CInFileStream;
    CMyComPtr<IInStream> file = fileSpec;
    if (!fileSpec->Open(us2fs(uPath)))
    {
      err = SZA_ERR_OPEN;
      goto done;
    }

    CArcOpenCallback *openCbSpec = new CArcOpenCallback;
    CMyComPtr<IArchiveOpenCallback> openCb(openCbSpec);
    openCbSpec->PasswordIsDefined = (utf8Password && *utf8Password);
    openCbSpec->Password = uPassword;

    const UInt64 scanSize = 1 << 23;
    if (archive->Open(file, &scanSize, openCb) != S_OK)
    {
      err = SZA_ERR_NOT_ARCHIVE;
      goto done;
    }
  }

  h = new CSzArchive;
  h->Archive = archive;
  h->PasswordIsDefined = (utf8Password && *utf8Password);
  h->Password = uPassword;
  result = (SzArchive)h;
  err = SZA_OK;

done:
  if (outErr) *outErr = err;
  return result;
}

SZ_API SzArchive SZ_CALL Sz_OpenFile(const char *utf8Path, const char *utf8Password)
{
  return Sz_OpenFileEx(utf8Path, utf8Password, NULL);
}

SZ_API int SZ_CALL Sz_GetItemCount(SzArchive a, uint32_t *count)
{
  CSzArchive *h = (CSzArchive *)a;
  if (!h || !count)
    return SZA_ERR_PARAM;
  UInt32 n = 0;
  if (h->Archive->GetNumberOfItems(&n) != S_OK)
    return SZA_ERR_PROPERTY;
  *count = n;
  return SZA_OK;
}

SZ_API int SZ_CALL Sz_GetItemPath(SzArchive a, uint32_t index,
    char *utf8Buf, int bufSize, int *needed)
{
  CSzArchive *h = (CSzArchive *)a;
  if (!h || bufSize < 0 || (bufSize > 0 && !utf8Buf))
    return SZA_ERR_PARAM;

  UInt32 n = 0;
  if (h->Archive->GetNumberOfItems(&n) != S_OK)
    return SZA_ERR_PROPERTY;
  if (index >= n)
    return SZA_ERR_INDEX;

  NCOM::CPropVariant prop;
  if (GetProp(h->Archive, index, kpidPath, prop) != S_OK)
    return SZA_ERR_PROPERTY;

  UString u;
  if (prop.vt == VT_BSTR)
    u = prop.bstrVal;
  else if (prop.vt != VT_EMPTY)
    return SZA_ERR_PROPERTY;

  AString utf8;
  UStringToUtf8(u, utf8);
  const int reqWithNul = (int)utf8.Len() + 1;
  if (needed)
    *needed = reqWithNul;

  if (bufSize < reqWithNul)
    return SZA_ERR_BUFFER_TOO_SMALL;

  memcpy(utf8Buf, utf8.Ptr(), (size_t)utf8.Len());
  utf8Buf[utf8.Len()] = 0;
  return SZA_OK;
}

SZ_API int SZ_CALL Sz_GetItemInfo(SzArchive a, uint32_t index,
    uint64_t *size, int *isDir, int64_t *mtimeUnix,
    uint32_t *crc32, int *crcDefined)
{
  CSzArchive *h = (CSzArchive *)a;
  if (!h)
    return SZA_ERR_PARAM;

  UInt32 n = 0;
  if (h->Archive->GetNumberOfItems(&n) != S_OK)
    return SZA_ERR_PROPERTY;
  if (index >= n)
    return SZA_ERR_INDEX;

  if (size)
  {
    UInt64 s = 0;
    GetItemSize(h->Archive, index, s);
    *size = s;
  }

  if (isDir)
  {
    bool d = false;
    GetItemIsDir(h->Archive, index, d);
    *isDir = d ? 1 : 0;
  }

  if (mtimeUnix)
  {
    *mtimeUnix = 0;
    NCOM::CPropVariant prop;
    if (GetProp(h->Archive, index, kpidMTime, prop) == S_OK && prop.vt == VT_FILETIME)
      *mtimeUnix = FileTimeToUnix(prop.filetime);
  }

  if (crc32 || crcDefined)
  {
    UInt32 c = 0;
    bool defined = false;
    NCOM::CPropVariant prop;
    if (GetProp(h->Archive, index, kpidCRC, prop) == S_OK && prop.vt == VT_UI4)
    {
      c = prop.ulVal;
      defined = true;
    }
    if (crc32) *crc32 = c;
    if (crcDefined) *crcDefined = defined ? 1 : 0;
  }

  return SZA_OK;
}

// Runs a single-item extraction with the given output stream attached.
static int ExtractOne(CSzArchive *h, uint32_t index, ISequentialOutStream *outStream)
{
  CArcExtractCallback *cbSpec = new CArcExtractCallback;
  CMyComPtr<IArchiveExtractCallback> cb(cbSpec);
  cbSpec->TargetIndex = index;
  cbSpec->OutStream = outStream;
  cbSpec->PasswordIsDefined = h->PasswordIsDefined;
  cbSpec->Password = h->Password;
  cbSpec->Progress = h->Progress;
  cbSpec->ProgressCtx = h->ProgressCtx;

  const UInt32 indices[1] = { (UInt32)index };
  const Int32 kNoTestMode = 0;
  HRESULT hr = h->Archive->Extract(indices, 1, kNoTestMode, cb);
  if (cbSpec->Cancelled)
    return SZA_ERR_CANCELLED;
  if (hr != S_OK)
  {
    // A wrong password surfaces here as an aborted/data error.
    return SZA_ERR_EXTRACT;
  }
  return OpResultToSz(cbSpec->OpResult);
}

SZ_API int SZ_CALL Sz_ExtractToFile(SzArchive a, uint32_t index, const char *utf8DestPath)
{
  CSzArchive *h = (CSzArchive *)a;
  if (!h || !utf8DestPath || !*utf8DestPath)
    return SZA_ERR_PARAM;

  UInt32 n = 0;
  if (h->Archive->GetNumberOfItems(&n) != S_OK)
    return SZA_ERR_PROPERTY;
  if (index >= n)
    return SZA_ERR_INDEX;

  UString uDest;
  if (!Utf8ToUString(utf8DestPath, uDest))
    return SZA_ERR_PARAM;
  const FString destPath = us2fs(uDest);

  // create parent directories
  {
    const int slash = uDest.ReverseFind_PathSepar();
    if (slash >= 0)
      NDir::CreateComplexDir(us2fs(uDest.Left(slash)));
  }

  bool isDir = false;
  GetItemIsDir(h->Archive, index, isDir);
  if (isDir)
  {
    return NDir::CreateComplexDir(destPath) ? SZA_OK : SZA_ERR_CREATE_FILE;
  }

  COutFileStream *outSpec = new COutFileStream;
  CMyComPtr<ISequentialOutStream> outStream(outSpec);
  if (!outSpec->Create_ALWAYS(destPath))
    return SZA_ERR_CREATE_FILE;

  const int res = ExtractOne(h, index, outStream);
  outSpec->Close();
  return res;
}

SZ_API int SZ_CALL Sz_ExtractToBuffer(SzArchive a, uint32_t index,
    void *buf, uint64_t bufSize, uint64_t *written)
{
  CSzArchive *h = (CSzArchive *)a;
  if (!h || (bufSize > 0 && !buf))
    return SZA_ERR_PARAM;
  if (written)
    *written = 0;

  UInt32 n = 0;
  if (h->Archive->GetNumberOfItems(&n) != S_OK)
    return SZA_ERR_PROPERTY;
  if (index >= n)
    return SZA_ERR_INDEX;

  bool isDir = false;
  GetItemIsDir(h->Archive, index, isDir);
  if (isDir)
    return SZA_ERR_PARAM; // directories have no content

  UInt64 itemSize = 0;
  GetItemSize(h->Archive, index, itemSize);
  if (written)
    *written = itemSize;
  if (bufSize < itemSize)
    return SZA_ERR_BUFFER_TOO_SMALL;

  CBufPtrSeqOutStream *outSpec = new CBufPtrSeqOutStream;
  CMyComPtr<ISequentialOutStream> outStream(outSpec);
  outSpec->Init((Byte *)buf, (size_t)itemSize);

  const int res = ExtractOne(h, index, outStream);
  if (res == SZA_OK && written)
    *written = outSpec->GetPos();
  return res;
}

SZ_API void SZ_CALL Sz_SetProgress(SzArchive a, Sz_ProgressFunc cb, void *ctx)
{
  CSzArchive *h = (CSzArchive *)a;
  if (!h)
    return;
  h->Progress = cb;
  h->ProgressCtx = ctx;
}

SZ_API int SZ_CALL Sz_ExtractToStream(SzArchive a, uint32_t index, Sz_WriteFunc writeFn, void *ctx)
{
  CSzArchive *h = (CSzArchive *)a;
  if (!h || !writeFn)
    return SZA_ERR_PARAM;

  UInt32 n = 0;
  if (h->Archive->GetNumberOfItems(&n) != S_OK)
    return SZA_ERR_PROPERTY;
  if (index >= n)
    return SZA_ERR_INDEX;

  bool isDir = false;
  GetItemIsDir(h->Archive, index, isDir);
  if (isDir)
    return SZA_ERR_PARAM; // directories have no content

  CCallbackOutStream *outSpec = new CCallbackOutStream;
  CMyComPtr<ISequentialOutStream> outStream(outSpec);
  outSpec->Func = writeFn;
  outSpec->Ctx = ctx;

  const int res = ExtractOne(h, index, outStream);
  if (res == SZA_ERR_EXTRACT && outSpec->UserError)
    return SZA_ERR_STREAM;
  return res;
}

SZ_API void SZ_CALL Sz_Close(SzArchive a)
{
  CSzArchive *h = (CSzArchive *)a;
  if (!h)
    return;
  if (h->Archive)
    h->Archive->Close();
  delete h;
}

SZ_API SzWriter SZ_CALL Sz_CreateArchive(const char *utf8Path, int level, const char *utf8Password)
{
  if (!utf8Path || !*utf8Path)
    return NULL;

  UString uPath, uPassword;
  if (!Utf8ToUString(utf8Path, uPath) || !Utf8ToUString(utf8Password, uPassword))
    return NULL;

  if (level < 0) level = 0;
  if (level > 9) level = 9;

  CSzWriter *w = new CSzWriter;
  w->ArcPath = us2fs(uPath);
  w->Level = level;
  w->PasswordIsDefined = (utf8Password && *utf8Password);
  w->Password = uPassword;
  return (SzWriter)w;
}

SZ_API int SZ_CALL Sz_AddFile(SzWriter wr, const char *utf8SrcPath, const char *utf8NameInArchive)
{
  CSzWriter *w = (CSzWriter *)wr;
  if (!w || !utf8SrcPath || !*utf8SrcPath)
    return SZA_ERR_PARAM;

  UString uSrc, uName;
  if (!Utf8ToUString(utf8SrcPath, uSrc))
    return SZA_ERR_PARAM;
  if (utf8NameInArchive && *utf8NameInArchive)
  {
    if (!Utf8ToUString(utf8NameInArchive, uName))
      return SZA_ERR_PARAM;
  }
  else
    uName = BaseNameFromPath(uSrc);

  const FString srcPath = us2fs(uSrc);
  NFile::NFind::CFileInfo fi;
  if (!fi.Find(srcPath))
    return SZA_ERR_ADD_SOURCE;

  CSzItem &it = w->Items.AddNew();
  it.Name = uName;
  it.FromFile = true;
  it.Fi = fi;
  it.FilePath = srcPath;
  it.IsDir = fi.IsDir();
  it.Size = fi.IsDir() ? 0 : fi.Size;
  return SZA_OK;
}

SZ_API int SZ_CALL Sz_AddBuffer(SzWriter wr, const char *utf8NameInArchive,
    const void *data, uint64_t len, int64_t mtimeUnix)
{
  CSzWriter *w = (CSzWriter *)wr;
  if (!w || !utf8NameInArchive || !*utf8NameInArchive || (len > 0 && !data))
    return SZA_ERR_PARAM;

  UString uName;
  if (!Utf8ToUString(utf8NameInArchive, uName))
    return SZA_ERR_PARAM;

  CSzItem &it = w->Items.AddNew();
  it.Name = uName;
  it.FromFile = false;
  it.IsDir = false;
  it.Size = len;
  if (len > 0)
    it.Buf.CopyFrom((const Byte *)data, (size_t)len);
  if (mtimeUnix > 0)
  {
    it.MTimeDefined = true;
    it.MTimeUnix = (UInt32)mtimeUnix;
  }
  return SZA_OK;
}

SZ_API int SZ_CALL Sz_AddEmptyDir(SzWriter wr, const char *utf8NameInArchive)
{
  CSzWriter *w = (CSzWriter *)wr;
  if (!w || !utf8NameInArchive || !*utf8NameInArchive)
    return SZA_ERR_PARAM;

  UString uName;
  if (!Utf8ToUString(utf8NameInArchive, uName))
    return SZA_ERR_PARAM;

  CSzItem &it = w->Items.AddNew();
  it.Name = uName;
  it.FromFile = false;
  it.IsDir = true;
  it.Size = 0;
  return SZA_OK;
}

SZ_API int SZ_CALL Sz_Writer_AddStream(SzWriter wr, const char *utf8NameInArchive,
    uint64_t size, int64_t mtimeUnix, Sz_ReadFunc readFn, void *ctx)
{
  CSzWriter *w = (CSzWriter *)wr;
  if (!w || !utf8NameInArchive || !*utf8NameInArchive || !readFn)
    return SZA_ERR_PARAM;

  UString uName;
  if (!Utf8ToUString(utf8NameInArchive, uName))
    return SZA_ERR_PARAM;

  CSzItem &it = w->Items.AddNew();
  it.Name = uName;
  it.FromStream = true;
  it.IsDir = false;
  it.Size = size;
  it.ReadFunc = readFn;
  it.ReadCtx = ctx;
  if (mtimeUnix > 0)
  {
    it.MTimeDefined = true;
    it.MTimeUnix = (UInt32)mtimeUnix;
  }
  return SZA_OK;
}

SZ_API void SZ_CALL Sz_Writer_SetProgress(SzWriter wr, Sz_ProgressFunc cb, void *ctx)
{
  CSzWriter *w = (CSzWriter *)wr;
  if (!w)
    return;
  w->Progress = cb;
  w->ProgressCtx = ctx;
}

SZ_API int SZ_CALL Sz_FinishArchive(SzWriter wr)
{
  CSzWriter *w = (CSzWriter *)wr;
  if (!w)
    return SZA_ERR_PARAM;

  int result = SZA_OK;

  CMyComPtr<IOutArchive> outArchive;
  if (CreateObject(&CLSID_Format_7z, &IID_IOutArchive, (void **)&outArchive) != S_OK || !outArchive)
  {
    result = SZA_ERR_UPDATE;
    goto cleanup;
  }

  // compression level
  {
    const wchar_t * const names[1] = { L"x" };
    NCOM::CPropVariant values[1];
    values[0] = (UInt32)w->Level;
    CMyComPtr<ISetProperties> setProperties;
    outArchive->QueryInterface(IID_ISetProperties, (void **)&setProperties);
    if (setProperties)
      setProperties->SetProperties(names, values, 1);
  }

  {
    COutFileStream *outSpec = new COutFileStream;
    CMyComPtr<IOutStream> outFile(outSpec);
    if (!outSpec->Create_ALWAYS(w->ArcPath))
    {
      result = SZA_ERR_CREATE_FILE;
      goto cleanup;
    }

    CArcUpdateCallback *cbSpec = new CArcUpdateCallback;
    CMyComPtr<IArchiveUpdateCallback2> cb(cbSpec);
    cbSpec->Items = &w->Items;
    cbSpec->PasswordIsDefined = w->PasswordIsDefined;
    cbSpec->Password = w->Password;
    cbSpec->Progress = w->Progress;
    cbSpec->ProgressCtx = w->ProgressCtx;

    const HRESULT hr = outArchive->UpdateItems(outFile, w->Items.Size(), cb);
    outSpec->Close();

    if (cbSpec->Cancelled)
      result = SZA_ERR_CANCELLED;
    else if (hr != S_OK || cbSpec->Failed)
      result = SZA_ERR_UPDATE;
  }

cleanup:
  delete w;
  return result;
}

SZ_API void SZ_CALL Sz_AbortArchive(SzWriter wr)
{
  CSzWriter *w = (CSzWriter *)wr;
  if (w)
    delete w;
}

SZ_API const char * SZ_CALL Sz_ErrorString(int code)
{
  switch (code)
  {
    case SZA_OK:                   return "OK";
    case SZA_ERR_PARAM:            return "Invalid argument";
    case SZA_ERR_OPEN:             return "Cannot open file";
    case SZA_ERR_NOT_ARCHIVE:      return "Not a valid 7z archive (or wrong password)";
    case SZA_ERR_INDEX:            return "Item index out of range";
    case SZA_ERR_EXTRACT:          return "Extraction failed (data, CRC or method error)";
    case SZA_ERR_BUFFER_TOO_SMALL: return "Output buffer too small";
    case SZA_ERR_MEMORY:           return "Out of memory";
    case SZA_ERR_PASSWORD:         return "Wrong or missing password";
    case SZA_ERR_PROPERTY:         return "Failed to read item property";
    case SZA_ERR_CREATE_FILE:      return "Cannot create output file";
    case SZA_ERR_UPDATE:           return "Archive creation / update failed";
    case SZA_ERR_ADD_SOURCE:       return "Cannot read a source file being added";
    case SZA_ERR_CANCELLED:        return "Operation cancelled by progress callback";
    case SZA_ERR_STREAM:           return "User stream callback failed";
    default:                      return "Unknown error";
  }
}

} // extern "C"
