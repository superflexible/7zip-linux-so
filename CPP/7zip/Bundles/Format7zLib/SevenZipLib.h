/* SevenZipLib.h -- simple flat C interface for the 7-Zip (7za) library.

   Phase 1: open / list / extract for the .7z format only.

   This header is the stable contract for non-C++ callers (e.g. Free Pascal /
   Delphi). It never exposes COM, BSTR or PROPVARIANT across the boundary.

   String convention: every string passed in or out of this API is a
   NUL-terminated 8-bit UTF-8 string. This is independent of the host OS
   locale.

   Calling convention: cdecl on every platform.
*/

#ifndef SEVEN_ZIP_LIB_H
#define SEVEN_ZIP_LIB_H

#include <stdint.h>

#if defined(_WIN32)
  #ifdef SZ_BUILD_DLL
    #define SZ_API __declspec(dllexport)
  #else
    #define SZ_API __declspec(dllimport)
  #endif
  #define SZ_CALL __cdecl
#else
  #define SZ_API __attribute__((visibility("default")))
  #define SZ_CALL
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to an opened archive. */
typedef void *SzArchive;

/* Return / error codes. Functions return SZA_OK (0) on success. */
enum
{
  SZA_OK                   = 0,
  SZA_ERR_PARAM            = 1,  /* invalid argument (e.g. NULL handle)        */
  SZA_ERR_OPEN             = 2,  /* cannot open the file on disk               */
  SZA_ERR_NOT_ARCHIVE      = 3,  /* file is not a valid .7z archive            */
  SZA_ERR_INDEX            = 4,  /* item index out of range                    */
  SZA_ERR_EXTRACT          = 5,  /* extraction failed (data/CRC/method error)  */
  SZA_ERR_BUFFER_TOO_SMALL = 6,  /* output buffer smaller than the item size   */
  SZA_ERR_MEMORY           = 7,  /* out of memory                              */
  SZA_ERR_PASSWORD         = 8,  /* archive is encrypted and password is wrong */
  SZA_ERR_PROPERTY         = 9,  /* failed to read an item property            */
  SZA_ERR_CREATE_FILE      = 10, /* cannot create the output file              */
  SZA_ERR_UPDATE           = 11, /* archive creation / update failed           */
  SZA_ERR_ADD_SOURCE       = 12, /* cannot read a source file being added      */
  SZA_ERR_CANCELLED        = 13, /* operation cancelled by a progress callback */
  SZA_ERR_STREAM           = 14  /* a user read/write stream callback failed   */
};

/* Progress callback, invoked periodically during extraction and creation.
   'completed' and 'total' are byte counts ('total' may be 0 when unknown).
   Return 0 to continue, or non-zero to cancel: the running operation then
   returns SZA_ERR_CANCELLED. */
typedef int (SZ_CALL *Sz_ProgressFunc)(void *ctx, uint64_t completed, uint64_t total);

/* Sink for Sz_ExtractToStream: write 'size' bytes from 'data'. Set *processed
   to the number of bytes consumed; a successful call must consume all of them.
   Return 0 on success, non-zero on error (extraction then fails). */
typedef int (SZ_CALL *Sz_WriteFunc)(void *ctx, const void *data, uint32_t size, uint32_t *processed);

/* Source for Sz_Writer_AddStream: read up to 'size' bytes into 'data'. Set
   *processed to the number of bytes produced (0 = end of stream). Return 0 on
   success, non-zero on error. */
typedef int (SZ_CALL *Sz_ReadFunc)(void *ctx, void *data, uint32_t size, uint32_t *processed);

/* Seek for a seekable stream (Sz_OpenStream / Sz_FinishArchiveToStream).
   origin: 0 = from start, 1 = from current, 2 = from end. Set *newPos to the
   resulting absolute position. Return 0 on success, non-zero on error. */
typedef int (SZ_CALL *Sz_SeekFunc)(void *ctx, int64_t offset, uint32_t origin, uint64_t *newPos);

/* Optional one-time initialisation. The library self-initialises on load, so
   calling this is not strictly required, but it is a convenient way to verify
   the library loaded correctly. Always returns SZA_OK. */
SZ_API int SZ_CALL Sz_GlobalInit(void);

/* Returns the 7-Zip version string (static storage, do not free). */
SZ_API const char * SZ_CALL Sz_VersionString(void);

/* Opens a .7z archive from a file path.
   utf8Password may be NULL (or "") for unencrypted archives.
   Returns a handle on success, or NULL on failure. Use Sz_OpenFileEx to get a
   specific error code. The handle must be released with Sz_Close. */
SZ_API SzArchive SZ_CALL Sz_OpenFile(const char *utf8Path, const char *utf8Password);

/* Same as Sz_OpenFile but reports a detailed error code via *outErr
   (outErr may be NULL). On failure returns NULL. */
SZ_API SzArchive SZ_CALL Sz_OpenFileEx(const char *utf8Path, const char *utf8Password, int *outErr);

/* Opens an archive from a seekable user stream (read + seek callbacks). The
   callbacks and ctx must stay valid until Sz_Close. *outErr may be NULL. */
SZ_API SzArchive SZ_CALL Sz_OpenStream(Sz_ReadFunc readFn, Sz_SeekFunc seekFn, void *ctx,
    const char *utf8Password, int *outErr);

/* Number of items (files and folders) in the archive. */
SZ_API int SZ_CALL Sz_GetItemCount(SzArchive a, uint32_t *count);

/* Copies the item path (UTF-8) into utf8Buf, NUL-terminated.
   bufSize is the size of utf8Buf in bytes.
   If 'needed' is non-NULL it receives the number of bytes required including
   the terminating NUL, so the caller can detect truncation / pre-size a buffer.
   Returns SZA_ERR_BUFFER_TOO_SMALL (and writes nothing) if bufSize is too
   small; *needed is still filled in that case. utf8Buf may be NULL only when
   bufSize == 0 (size-query mode). */
SZ_API int SZ_CALL Sz_GetItemPath(SzArchive a, uint32_t index,
    char *utf8Buf, int bufSize, int *needed);

/* Retrieves item metadata. Any out-pointer may be NULL if not wanted.
     size       : uncompressed size in bytes
     isDir      : 1 if the item is a directory, 0 otherwise
     mtimeUnix  : modification time as Unix time (seconds since 1970), 0 if none
     crc32      : CRC-32 of the item
     crcDefined : 1 if crc32 is valid, 0 otherwise */
SZ_API int SZ_CALL Sz_GetItemInfo(SzArchive a, uint32_t index,
    uint64_t *size, int *isDir, int64_t *mtimeUnix,
    uint32_t *crc32, int *crcDefined);

/* Extracts one item to a file on disk. Parent directories of utf8DestPath are
   created as needed. A directory item creates an empty directory. */
SZ_API int SZ_CALL Sz_ExtractToFile(SzArchive a, uint32_t index, const char *utf8DestPath);

/* Registers a progress callback used by subsequent extractions on this
   archive handle. Pass cb = NULL to disable. ctx is passed back unchanged. */
SZ_API void SZ_CALL Sz_SetProgress(SzArchive a, Sz_ProgressFunc cb, void *ctx);

/* Sets (or clears, with NULL/"") the password used for extracting from this
   archive. Useful when an archive with readable headers but encrypted content
   was opened without a password. */
SZ_API void SZ_CALL Sz_SetPassword(SzArchive a, const char *utf8Password);

/* Extracts one item, delivering its uncompressed bytes to a user write
   callback (e.g. wrapping a stream). */
SZ_API int SZ_CALL Sz_ExtractToStream(SzArchive a, uint32_t index, Sz_WriteFunc writeFn, void *ctx);

/* Extracts one item into a caller-provided memory buffer.
   bufSize is the capacity of buf in bytes.
   On success *written (if non-NULL) receives the number of bytes written.
   If the buffer is too small the function returns SZA_ERR_BUFFER_TOO_SMALL and,
   when *written is non-NULL, sets it to the required size. Querying the
   required size is also possible by passing buf=NULL, bufSize=0. */
SZ_API int SZ_CALL Sz_ExtractToBuffer(SzArchive a, uint32_t index,
    void *buf, uint64_t bufSize, uint64_t *written);

/* Closes an archive handle and frees all associated resources.
   Passing NULL is a no-op. */
SZ_API void SZ_CALL Sz_Close(SzArchive a);

/* Returns a static human-readable description for an SZ_* error code. */
SZ_API const char * SZ_CALL Sz_ErrorString(int code);

/* =========================================================================
   Phase 2 -- creating .7z archives
   =========================================================================

   Usage:
     SzWriter w = Sz_CreateArchive("out.7z", 5, NULL);
     Sz_AddFile(w, "/path/file.txt", "file.txt");
     Sz_AddBuffer(w, "generated.bin", data, len, 0);
     int rc = Sz_FinishArchive(w);   // writes the file and frees the writer

   Nothing is written to disk until Sz_FinishArchive. Use Sz_AbortArchive to
   discard a writer without producing a file. A writer is single-use: after
   Sz_FinishArchive or Sz_AbortArchive the handle is invalid.
   Writers are not thread-safe; do not share one across threads.
*/

/* Opaque handle to an archive being built. */
typedef void *SzWriter;

/* Begins a new .7z archive.
     utf8Path     : destination file used by Sz_FinishArchive; may be NULL/""
                    if you intend to finish with Sz_FinishArchiveToFile or
                    Sz_FinishArchiveToStream instead
     level        : compression level 0..9 (0 = store, 9 = ultra); clamped
     utf8Password : NULL/"" for none; otherwise the file contents are AES-256
                    encrypted (see Sz_Writer_SetHeaderEncryption for headers)
   Returns a writer handle, or NULL on invalid arguments. */
SZ_API SzWriter SZ_CALL Sz_CreateArchive(const char *utf8Path, int level, const char *utf8Password);

/* Overrides the compression level / password after creation (before finish). */
SZ_API void SZ_CALL Sz_Writer_SetLevel(SzWriter w, int level);
SZ_API void SZ_CALL Sz_Writer_SetPassword(SzWriter w, const char *utf8Password);

/* Queues a file (or an empty directory) from disk for addition.
   utf8NameInArchive is the path the item will have inside the archive; if NULL
   the source's own file name is used. Metadata (size, times, attributes) is
   captured now from disk, but the content is read later, during
   Sz_FinishArchive. */
SZ_API int SZ_CALL Sz_AddFile(SzWriter w, const char *utf8SrcPath, const char *utf8NameInArchive);

/* Queues an in-memory buffer as an archive item. The bytes are copied
   immediately, so the caller may free 'data' right after this call.
   mtimeUnix is the modification time in Unix seconds (pass 0 for none). */
SZ_API int SZ_CALL Sz_AddBuffer(SzWriter w, const char *utf8NameInArchive,
    const void *data, uint64_t len, int64_t mtimeUnix);

/* Queues an empty directory entry. */
SZ_API int SZ_CALL Sz_AddEmptyDir(SzWriter w, const char *utf8NameInArchive);

/* Queues an item whose content is produced by a user read callback (e.g.
   wrapping a stream). 'size' is the exact number of bytes that will be read
   and must be known up front. The callback and ctx must remain valid until
   Sz_FinishArchive or Sz_AbortArchive is called. */
SZ_API int SZ_CALL Sz_Writer_AddStream(SzWriter w, const char *utf8NameInArchive,
    uint64_t size, int64_t mtimeUnix, Sz_ReadFunc readFn, void *ctx);

/* Registers a progress callback used by Sz_FinishArchive. Pass cb = NULL to
   disable. */
SZ_API void SZ_CALL Sz_Writer_SetProgress(SzWriter w, Sz_ProgressFunc cb, void *ctx);

/* Enables (enable != 0) or disables encryption of the archive headers
   (file names, sizes, structure) in addition to the file contents. Only takes
   effect when the archive was created with a password. Off by default. */
SZ_API void SZ_CALL Sz_Writer_SetHeaderEncryption(SzWriter w, int enable);

/* Compresses all queued items, writes the archive to disk and frees the
   writer (valid or not, the handle must not be used afterwards). All three
   Finish variants free the writer. */
SZ_API int SZ_CALL Sz_FinishArchive(SzWriter w);

/* Like Sz_FinishArchive but writes to the given path (ignores the path passed
   to Sz_CreateArchive). */
SZ_API int SZ_CALL Sz_FinishArchiveToFile(SzWriter w, const char *utf8Path);

/* Like Sz_FinishArchive but writes the archive to a seekable user stream
   (write + seek callbacks). 7z needs to seek the output, so both are required. */
SZ_API int SZ_CALL Sz_FinishArchiveToStream(SzWriter w, Sz_WriteFunc writeFn, Sz_SeekFunc seekFn, void *ctx);

/* Discards a writer without writing anything. Passing NULL is a no-op. */
SZ_API void SZ_CALL Sz_AbortArchive(SzWriter w);

#ifdef __cplusplus
}
#endif

#endif /* SEVEN_ZIP_LIB_H */
