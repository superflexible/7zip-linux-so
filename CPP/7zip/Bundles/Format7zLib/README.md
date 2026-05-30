# lib7za — flat C interface to the 7za (.7z) code base

This bundle builds a Linux `.so` / macOS `.dylib` (and, secondarily, a Windows
`.dll`) that wraps the self-contained **7za** code base (7z format only, with the
built-in codecs: LZMA, LZMA2, PPMd, BCJ/BCJ2, Delta, Copy, Deflate-decode,
BZip2-decode and AES-256) behind a **simple flat C API** — no COM, no `BSTR`, no
`PROPVARIANT` cross the boundary.

It is intended for use from Free Pascal (and any language that can call C),
with all strings as 8-bit **UTF-8** and **cdecl** calling convention.

## Capabilities

- Open a `.7z` archive from a file or a seekable stream; enumerate items and
  read their metadata (path, size, directory flag, modification time, CRC-32).
- Extract items to a file, a memory buffer, or a user-supplied stream.
- Create a `.7z` archive from files on disk, in-memory buffers, or user streams,
  with a selectable compression level (0–9).
- AES-256 encryption of file contents, and optionally of the archive headers.
- Progress reporting with cancellation for both extraction and creation.

## Files

| File | Purpose |
|------|---------|
| `SevenZipLib.h`   | public C API (the contract) |
| `SevenZipLib.cpp` | wrapper implementation (drives the in-process COM objects) |
| `SevenZipLib.pas` | Free Pascal import unit (flat API) |
| `SevenZipClasses.pas` | Free Pascal `T7zInArchive` / `T7zOutArchive` classes (migration helper) |
| `test7za.pas`     | Free Pascal command-line test driver (list / extract / create) |
| `test7za_features.pas` | Free Pascal self-test for progress / streaming / cancellation (no args) |
| `test7zclasses.pas` | Free Pascal self-test for the `T7zInArchive` / `T7zOutArchive` classes (no args) |
| `SevenZipLib.def` | export list (used by the MinGW/Windows build) |
| `Arc7z_gcc.mak`   | reduced object list (7z-only subset of `Format7zF/Arc_gcc.mak`) |
| `makefile.gcc`    | Linux/macOS/MinGW build |
| `example.c`       | minimal C usage sample |
| `StdAfx.{h,cpp}`  | precompiled-header stub (as in the other bundles) |

## Building

Run from **inside this directory** (`CPP/7zip/Bundles/Format7zLib`).
The 7-Zip gcc build wrappers expect that working directory.

### Linux (x86-64, gcc)

```sh
make -f ../../cmpl_gcc_x64.mak USE_ASM= -j
# -> b/g_x64/lib7za.so
```

`USE_ASM=` disables the optional asm objects so you don't need the `asmc`
assembler; the C codec paths are used instead. Drop it (and install `asmc`) if
you want the asm-accelerated CRC/AES/SHA paths.

For other gcc targets use the matching wrapper:
`../../cmpl_gcc_x86.mak`, `../../cmpl_gcc_arm64.mak`, `../../cmpl_gcc_arm.mak`.
With clang, use the `cmpl_clang_*.mak` wrappers.

### macOS (clang) — produce a `.dylib`

```sh
# Apple silicon:
make -f ../../cmpl_mac_arm64.mak USE_ASM= \
     SHARED_EXT=.dylib MY_LIBS="-Wl,-install_name,@rpath/lib7za.dylib" -j
# -> b/m_arm64/lib7za.dylib

# Intel:
make -f ../../cmpl_mac_x64.mak USE_ASM= \
     SHARED_EXT=.dylib MY_LIBS="-Wl,-install_name,@rpath/lib7za.dylib" -j
# -> b/m_x64/lib7za.dylib
```

### Windows (MinGW) — optional

```sh
mingw32-make -f makefile.gcc
```
On Windows the export list comes from `SevenZipLib.def`. (On Windows you can
also keep using your existing COM-style import unit against `7za.dll`; this
wrapper is provided mainly for the Unix targets.)

### Output location

The `O` output directory is set by the var wrapper (`b/g_x64`, `b/m_arm64`, …).
Copy the resulting `lib7za.so` / `lib7za.dylib` next to your executable, or onto
the loader search path / rpath.

## Class-based API for migration (`SevenZipClasses.pas`)

For code migrating from the COM-based `7z.dll` wrappers, `SevenZipClasses.pas`
provides `T7zInArchive` / `T7zOutArchive` with familiar shapes, built on the
flat API. Streams are `TStream` (not COM), callbacks are plain
`(sender: Pointer; ...)` procedures, errors raise `E7zException`.

```pascal
uses Classes, SevenZipClasses;

var arc: T7zInArchive; ms: TMemoryStream; i: Cardinal;
begin
  arc := T7zInArchive.Create;
  try
    arc.SetPassword('secret');         // optional; before OpenFile
    arc.OpenFile('data.7z');           // or arc.OpenStream(aTStream)
    for i := 0 to arc.NumberOfItems - 1 do
      WriteLn(arc.ItemPath[i], '  ', arc.ItemSize[i]);
    ms := TMemoryStream.Create;
    arc.ExtractItem(0, ms, False);     // extract item 0 into a TStream
    ms.Free;
    arc.ExtractTo('/tmp/out');         // extract everything to a folder
  finally
    arc.Free;
  end;
end;

var outa: T7zOutArchive;
begin
  outa := T7zOutArchive.Create;
  try
    outa.SetPassword('secret');
    outa.EncryptHeaders := True;
    outa.AddFile('/etc/hostname', 'hostname', 0, Default(TFileTime), Default(TFileTime), 0);
    outa.AddFiles('/var/log', 'logs', '*.log', True);
    outa.SaveToFile('backup.7z');      // or outa.SaveToStream(aTStream)
  finally
    outa.Free;
  end;
end;
```

Notes / adaptations from the COM unit:
- `.7z` format only (this is the 7za code base).
- `OpenStream`/`SaveToStream` use seekable `TStream`s (7z seeks its I/O).
- Per-item `Attributes`, `CreationTime`, `Comment`, `IsAnti` are accepted for
  signature compatibility but not stored by the library; size, path and
  modification time are honoured.
- `Add*` return the queued item's index (`T7zBatchItem = Cardinal`).
- A `TStream` added with `soOwned` is freed by the archive after `SaveTo*`.

## Using from Free Pascal (flat API)

```pascal
uses SevenZipLib;
var
  a: TSzArchive;
  i, n: LongWord;
  size: QWord;
  isDir, err: LongInt;
begin
  a := Sz_OpenFileEx('test.7z', nil, @err);
  if a = nil then
    raise Exception.Create(Sz_ErrorString(err));
  Sz_GetItemCount(a, n);
  for i := 0 to n - 1 do
  begin
    size := 0; isDir := 0;
    Sz_GetItemInfo(a, i, @size, @isDir, nil, nil, nil);
    WriteLn(Sz_ItemPath(a, i), '  ', size);
  end;
  Sz_ExtractToFile(a, 0, '/tmp/out.bin');
  Sz_Close(a);
end;
```

Make sure FPC can locate the shared library at run time (same directory as the
binary, `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`, or an rpath).

### Command-line test driver (`test7za.pas`)

```sh
# build lib7za first (see above), then:
fpc -Fu. -Fl./b/g_x64 -k'-rpath=$ORIGIN/b/g_x64' test7za.pas

# round-trip smoke test:
./test7za c test.7z SevenZipLib.h README.md   # create
./test7za l test.7z                            # list
./test7za x test.7z /tmp/out                   # extract all
./test7za xb test.7z 0                         # extract item 0 to memory
./test7za cp secret enc.7z SevenZipLib.h       # create encrypted
./test7za l enc.7z secret                      # list with password
```

`-Fl` adds the library search dir at link time and `-k'-rpath=...'` bakes in a
run-time search path; alternatively set `LD_LIBRARY_PATH=./b/g_x64` when running.

### Feature self-test (`test7za_features.pas`)

A no-arguments test that builds archives in the current directory and checks the
progress callbacks, `TStream` extract/add helpers, cancellation, and AES
round-trip, printing PASS/FAIL and exiting non-zero on any failure:

```sh
fpc -Fu. -Fl./b/g_x64 -k'-rpath=$ORIGIN/b/g_x64' test7za_features.pas
./test7za_features
```

### Class self-test (`test7zclasses.pas`)

Exercises `T7zInArchive` / `T7zOutArchive`: build (AddString/AddStream/AddFile/
AddFiles), SaveToFile and SaveToStream, OpenFile and OpenStream, item
properties, ExtractItem (and test mode), ExtractItems, ExtractAll, ExtractTo,
progress, cancellation, and (header) encryption.

```sh
fpc -Fu. -Fl./b/g_x64 -k'-rpath=$ORIGIN/b/g_x64' test7zclasses.pas
./test7zclasses
```

## API summary

See `SevenZipLib.h` for the authoritative documentation. Functions return
`SZA_OK` (0) on success or an `SZA_ERR_*` code; `Sz_ErrorString` maps codes to text.

- `Sz_OpenFile` / `Sz_OpenFileEx` — open a `.7z` file (optional password)
- `Sz_GetItemCount` — number of items
- `Sz_GetItemPath` — item path (UTF-8); supports size-query via `bufSize = 0`
- `Sz_GetItemInfo` — size / isDir / mtime / CRC-32
- `Sz_ExtractToFile` — extract one item to disk
- `Sz_ExtractToBuffer` — extract one item into a caller buffer
- `Sz_Close` — release the handle

Creating archives:

- `Sz_CreateArchive` — start a new `.7z` (path, level 0..9, optional password)
- `Sz_AddFile` — queue a file (or empty dir) from disk
- `Sz_AddBuffer` — queue an in-memory buffer (copied immediately)
- `Sz_AddEmptyDir` — queue an empty directory entry
- `Sz_FinishArchive` — compress, write to disk, and free the writer
- `Sz_AbortArchive` — discard the writer without writing

```pascal
var w: TSzWriter;
begin
  w := Sz_CreateArchive('out.7z', 5, nil);
  Sz_AddFile(w, '/etc/hostname', 'hostname');
  Sz_AddBuffer(w, 'note.txt', PAnsiChar(s)^, Length(s), 0);
  if Sz_FinishArchive(w) <> SZA_OK then
    WriteLn('compression failed');
end;
```

Note: with a password, item **contents** are AES-256 encrypted. By default the
archive **headers** (file names, sizes) are left readable. To encrypt them too,
call `Sz_Writer_SetHeaderEncryption(w, 1)` after `Sz_CreateArchive` (only
effective when a password is set). With header encryption on, the archive
cannot even be opened/listed without the correct password.

```pascal
w := Sz_CreateArchive('secret.7z', 5, 'password');
Sz_Writer_SetHeaderEncryption(w, 1);   // encrypt names + sizes too
Sz_AddFile(w, '/etc/hostname', 'hostname');
Sz_FinishArchive(w);
```

### Progress callbacks and streaming

Progress (byte counts) for long operations, with cancellation:

- `Sz_SetProgress(a, cb, ctx)` — progress for extractions on an archive handle
- `Sz_Writer_SetProgress(w, cb, ctx)` — progress for `Sz_FinishArchive`

The callback is `int cb(void *ctx, uint64_t completed, uint64_t total)`; return
non-zero to cancel — the operation then returns `SZA_ERR_CANCELLED`.

Stream in/out via user callbacks (no temp files):

- `Sz_ExtractToStream(a, index, writeFn, ctx)` — extract an item through a write callback
- `Sz_Writer_AddStream(w, name, size, mtime, readFn, ctx)` — add an item from a read callback (size known up front)

From Free Pascal, the unit wraps these around `TStream` for you:

```pascal
uses Classes, SevenZipLib;

// progress (a plain cdecl function; return 1 to cancel)
function OnProgress(ctx: Pointer; completed, total: QWord): LongInt; cdecl;
begin
  WriteLn(Format('%d / %d bytes', [completed, total]));
  Result := 0;
end;

// extract item 0 into any TStream
var ms: TMemoryStream;
begin
  ms := TMemoryStream.Create;
  Sz_SetProgress(a, @OnProgress, nil);
  if Sz_ExtractToTStream(a, 0, ms) = SZA_OK then
    ms.SaveToFile('out.bin');
  ms.Free;
end;

// add a file from a TStream while creating an archive
var fs: TFileStream;
begin
  fs := TFileStream.Create('big.dat', fmOpenRead);
  Sz_Writer_SetProgress(w, @OnProgress, nil);
  Sz_Writer_AddTStream(w, 'big.dat', fs);   // reads from current position to end
  Sz_FinishArchive(w);
  fs.Free;   // keep the stream alive until FinishArchive returns
end;
```

The `TStream` passed to `Sz_Writer_AddTStream` must stay alive until
`Sz_FinishArchive`/`Sz_AbortArchive`, because its content is read lazily during
finish (same as files added with `Sz_AddFile`).
