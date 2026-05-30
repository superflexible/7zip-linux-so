{ SevenZipLib.pas -- Free Pascal import unit for lib7za.

  Flat C interface around the 7-Zip (7za, .7z-only) code base for
  Linux and macOS: open / list / extract and create .7z archives, with
  progress callbacks and TStream-based extract/add helpers.
  All strings are 8-bit UTF-8 (PAnsiChar).

  Build the shared library from CPP/7zip/Bundles/Format7zLib (see README.md),
  then place lib7za.so / lib7za.dylib where the OS loader can find it
  (next to the executable, or on the library search path / rpath).

  Tested with FPC 3.2+. Calling convention is cdecl on all platforms. }

unit SevenZipLib;

{$mode objfpc}{$H+}

interface

uses
  Classes;

const
{$IFDEF WINDOWS}
  SevenZipLibName = 'lib7za.dll';
{$ENDIF}
{$IFDEF DARWIN}
  SevenZipLibName = 'lib7za.dylib';
{$ENDIF}
{$IFDEF LINUX}
  SevenZipLibName = 'lib7za.so';
{$ENDIF}

  { Return / error codes (must match SevenZipLib.h). }
  SZA_OK                   = 0;
  SZA_ERR_PARAM            = 1;
  SZA_ERR_OPEN             = 2;
  SZA_ERR_NOT_ARCHIVE      = 3;
  SZA_ERR_INDEX            = 4;
  SZA_ERR_EXTRACT          = 5;
  SZA_ERR_BUFFER_TOO_SMALL = 6;
  SZA_ERR_MEMORY           = 7;
  SZA_ERR_PASSWORD         = 8;
  SZA_ERR_PROPERTY         = 9;
  SZA_ERR_CREATE_FILE      = 10;
  SZA_ERR_UPDATE           = 11;
  SZA_ERR_ADD_SOURCE       = 12;
  SZA_ERR_CANCELLED        = 13;
  SZA_ERR_STREAM           = 14;

type
  TSzArchive = Pointer;
  TSzWriter  = Pointer;

  { Raw C callback types (cdecl). Return 0 for success / continue. }
  TSzProgressFunc = function(ctx: Pointer; completed, total: QWord): LongInt; cdecl;
  TSzWriteFunc    = function(ctx: Pointer; data: Pointer; size: LongWord; processed: PLongWord): LongInt; cdecl;
  TSzReadFunc     = function(ctx: Pointer; data: Pointer; size: LongWord; processed: PLongWord): LongInt; cdecl;
  { origin: 0 = from start, 1 = from current, 2 = from end }
  TSzSeekFunc     = function(ctx: Pointer; offset: Int64; origin: LongWord; newPos: PQWord): LongInt; cdecl;

function Sz_GlobalInit: LongInt; cdecl;
  external SevenZipLibName name 'Sz_GlobalInit';

function Sz_VersionString: PAnsiChar; cdecl;
  external SevenZipLibName name 'Sz_VersionString';

function Sz_OpenFile(utf8Path, utf8Password: PAnsiChar): TSzArchive; cdecl;
  external SevenZipLibName name 'Sz_OpenFile';

function Sz_OpenFileEx(utf8Path, utf8Password: PAnsiChar; outErr: PLongInt): TSzArchive; cdecl;
  external SevenZipLibName name 'Sz_OpenFileEx';

function Sz_OpenStream(readFn: TSzReadFunc; seekFn: TSzSeekFunc; ctx: Pointer;
  utf8Password: PAnsiChar; outErr: PLongInt): TSzArchive; cdecl;
  external SevenZipLibName name 'Sz_OpenStream';

function Sz_GetItemCount(a: TSzArchive; out count: LongWord): LongInt; cdecl;
  external SevenZipLibName name 'Sz_GetItemCount';

function Sz_GetItemPath(a: TSzArchive; index: LongWord;
  utf8Buf: PAnsiChar; bufSize: LongInt; needed: PLongInt): LongInt; cdecl;
  external SevenZipLibName name 'Sz_GetItemPath';

function Sz_GetItemInfo(a: TSzArchive; index: LongWord;
  size: PQWord; isDir: PLongInt; mtimeUnix: PInt64;
  crc32: PLongWord; crcDefined: PLongInt): LongInt; cdecl;
  external SevenZipLibName name 'Sz_GetItemInfo';

function Sz_ExtractToFile(a: TSzArchive; index: LongWord; utf8DestPath: PAnsiChar): LongInt; cdecl;
  external SevenZipLibName name 'Sz_ExtractToFile';

function Sz_ExtractToBuffer(a: TSzArchive; index: LongWord;
  buf: Pointer; bufSize: QWord; written: PQWord): LongInt; cdecl;
  external SevenZipLibName name 'Sz_ExtractToBuffer';

procedure Sz_SetProgress(a: TSzArchive; cb: TSzProgressFunc; ctx: Pointer); cdecl;
  external SevenZipLibName name 'Sz_SetProgress';

procedure Sz_SetPassword(a: TSzArchive; utf8Password: PAnsiChar); cdecl;
  external SevenZipLibName name 'Sz_SetPassword';

function Sz_ExtractToStream(a: TSzArchive; index: LongWord;
  writeFn: TSzWriteFunc; ctx: Pointer): LongInt; cdecl;
  external SevenZipLibName name 'Sz_ExtractToStream';

procedure Sz_Close(a: TSzArchive); cdecl;
  external SevenZipLibName name 'Sz_Close';

function Sz_ErrorString(code: LongInt): PAnsiChar; cdecl;
  external SevenZipLibName name 'Sz_ErrorString';

{ ---- Phase 2: creating .7z archives ---- }

function Sz_CreateArchive(utf8Path: PAnsiChar; level: LongInt; utf8Password: PAnsiChar): TSzWriter; cdecl;
  external SevenZipLibName name 'Sz_CreateArchive';

procedure Sz_Writer_SetLevel(w: TSzWriter; level: LongInt); cdecl;
  external SevenZipLibName name 'Sz_Writer_SetLevel';

procedure Sz_Writer_SetPassword(w: TSzWriter; utf8Password: PAnsiChar); cdecl;
  external SevenZipLibName name 'Sz_Writer_SetPassword';

function Sz_AddFile(w: TSzWriter; utf8SrcPath, utf8NameInArchive: PAnsiChar): LongInt; cdecl;
  external SevenZipLibName name 'Sz_AddFile';

function Sz_AddBuffer(w: TSzWriter; utf8NameInArchive: PAnsiChar;
  data: Pointer; len: QWord; mtimeUnix: Int64): LongInt; cdecl;
  external SevenZipLibName name 'Sz_AddBuffer';

function Sz_AddEmptyDir(w: TSzWriter; utf8NameInArchive: PAnsiChar): LongInt; cdecl;
  external SevenZipLibName name 'Sz_AddEmptyDir';

function Sz_Writer_AddStream(w: TSzWriter; utf8NameInArchive: PAnsiChar;
  size: QWord; mtimeUnix: Int64; readFn: TSzReadFunc; ctx: Pointer): LongInt; cdecl;
  external SevenZipLibName name 'Sz_Writer_AddStream';

procedure Sz_Writer_SetProgress(w: TSzWriter; cb: TSzProgressFunc; ctx: Pointer); cdecl;
  external SevenZipLibName name 'Sz_Writer_SetProgress';

{ Encrypt archive headers (names/sizes) too; only effective with a password. }
procedure Sz_Writer_SetHeaderEncryption(w: TSzWriter; enable: LongInt); cdecl;
  external SevenZipLibName name 'Sz_Writer_SetHeaderEncryption';

function Sz_FinishArchive(w: TSzWriter): LongInt; cdecl;
  external SevenZipLibName name 'Sz_FinishArchive';

function Sz_FinishArchiveToFile(w: TSzWriter; utf8Path: PAnsiChar): LongInt; cdecl;
  external SevenZipLibName name 'Sz_FinishArchiveToFile';

function Sz_FinishArchiveToStream(w: TSzWriter; writeFn: TSzWriteFunc;
  seekFn: TSzSeekFunc; ctx: Pointer): LongInt; cdecl;
  external SevenZipLibName name 'Sz_FinishArchiveToStream';

procedure Sz_AbortArchive(w: TSzWriter); cdecl;
  external SevenZipLibName name 'Sz_AbortArchive';

{ ---- convenience helpers ---- }

{ Returns the item path as a Pascal UTF-8 string. }
function Sz_ItemPath(a: TSzArchive; index: LongWord): UTF8String;

{ Extracts one item, writing its bytes into a TStream (at the stream's current
  position). Set a progress callback first with Sz_SetProgress if desired. }
function Sz_ExtractToTStream(a: TSzArchive; index: LongWord; dest: TStream): LongInt;

{ Adds an item whose content is read from a TStream, starting at the stream's
  current position through to the end. The stream must stay alive (and ideally
  not be modified) until Sz_FinishArchive / Sz_AbortArchive. }
function Sz_Writer_AddTStream(w: TSzWriter; const NameInArchive: RawByteString;
  src: TStream; mtimeUnix: Int64 = 0): LongInt;

implementation

{ cdecl trampolines that bridge the C callbacks to a TStream passed as ctx. }

function TStreamWriteThunk(ctx: Pointer; data: Pointer; size: LongWord;
  processed: PLongWord): LongInt; cdecl;
var
  n: LongInt;
begin
  n := TStream(ctx).Write(PByte(data)^, size);
  if processed <> nil then
    processed^ := LongWord(n);
  if LongWord(n) = size then Result := 0 else Result := 1;
end;

function TStreamReadThunk(ctx: Pointer; data: Pointer; size: LongWord;
  processed: PLongWord): LongInt; cdecl;
var
  n: LongInt;
begin
  n := TStream(ctx).Read(PByte(data)^, size);  { n = 0 signals end of stream }
  if processed <> nil then
    processed^ := LongWord(n);
  Result := 0;
end;

function Sz_ExtractToTStream(a: TSzArchive; index: LongWord; dest: TStream): LongInt;
begin
  Result := Sz_ExtractToStream(a, index, @TStreamWriteThunk, Pointer(dest));
end;

function Sz_Writer_AddTStream(w: TSzWriter; const NameInArchive: RawByteString;
  src: TStream; mtimeUnix: Int64 = 0): LongInt;
begin
  Result := Sz_Writer_AddStream(w, PAnsiChar(NameInArchive),
    QWord(src.Size - src.Position), mtimeUnix, @TStreamReadThunk, Pointer(src));
end;

function Sz_ItemPath(a: TSzArchive; index: LongWord): UTF8String;
var
  needed: LongInt;
begin
  Result := '';
  needed := 0;
  { Size query: returns SZA_ERR_BUFFER_TOO_SMALL and fills 'needed'
    (bytes required, including the terminating NUL). }
  Sz_GetItemPath(a, index, nil, 0, @needed);
  if needed <= 0 then
    Exit;
  SetLength(Result, needed - 1);
  if Sz_GetItemPath(a, index, PAnsiChar(Result), needed, nil) <> SZA_OK then
    Result := '';
end;

end.
