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

{ ---------------------------------------------------------------------------
  SEVENZIPDYNAMIC -- how the library is bound.

  NOT defined (default): the Sz_* functions are ordinary imports, so the
    library is a hard dependency of the executable and is loaded by the OS at
    program start.  The project must then link against it: pass -Fl<dir> and,
    on Darwin, an rpath (the library's install name is @rpath/lib7za.dylib),
    for example -k-rpath -k@executable_path/../lib64.

  Defined (compile with -dSEVENZIPDYNAMIC, or add {$define SEVENZIPDYNAMIC}
    above the unit header): the Sz_* entry points become procedure
    variables and the library is loaded lazily with dlopen / LoadLibrary the
    first time an archive is actually opened or created -- see
    SevenZipLibAvailable below.  Nothing is loaded if the program never
    touches a .7z file, the executable has no link-time dependency on the
    library, and a missing library is a catchable error instead of a failure
    to start.  The library is expected next to the program binary.

    Every caller of the flat API must then call SevenZipLibAvailable (and
    honour a False result) before the first Sz_* call -- the entry points are
    nil until the library has been loaded.  SevenZipClasses.pas does this on
    its own, so users of T7zInArchive / T7zOutArchive need no changes.
  --------------------------------------------------------------------------- }

{$ifndef SEVENZIPDYNAMIC}
{ On Darwin, FPC 3.2.x ignores the library name given in "external '<lib>'"
  when it builds the linker command line (no -l flag is emitted at all), so
  every Sz_* import ends up as an undefined symbol.  Name the library
  explicitly and add the unit's own directory to the library search path.
  On Linux and Windows the "external SevenZipLibName" declarations below are
  enough, so nothing extra is linked in there. }
{$IFDEF DARWIN}
  {$LINKLIB 7za}
  {$LIBRARYPATH .}
{$ENDIF}
{$endif}

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

{$ifdef SEVENZIPDYNAMIC}

{ Bound by SevenZipLibAvailable; nil until the library has been loaded.
  The declarations are kept identical to the static ones below. }
var
  Sz_GlobalInit: function: LongInt; cdecl;

  Sz_VersionString: function: PAnsiChar; cdecl;

  Sz_OpenFile: function(utf8Path, utf8Password: PAnsiChar): TSzArchive; cdecl;

  Sz_OpenFileEx: function(utf8Path, utf8Password: PAnsiChar; outErr: PLongInt): TSzArchive; cdecl;

  Sz_OpenStream: function(readFn: TSzReadFunc; seekFn: TSzSeekFunc; ctx: Pointer;
    utf8Password: PAnsiChar; outErr: PLongInt): TSzArchive; cdecl;

  Sz_GetItemCount: function(a: TSzArchive; out count: LongWord): LongInt; cdecl;

  Sz_GetItemPath: function(a: TSzArchive; index: LongWord;
    utf8Buf: PAnsiChar; bufSize: LongInt; needed: PLongInt): LongInt; cdecl;

  Sz_GetItemInfo: function(a: TSzArchive; index: LongWord;
    size: PQWord; isDir: PLongInt; mtimeUnix: PInt64;
    crc32: PLongWord; crcDefined: PLongInt): LongInt; cdecl;

  Sz_ExtractToFile: function(a: TSzArchive; index: LongWord; utf8DestPath: PAnsiChar): LongInt; cdecl;

  Sz_ExtractToBuffer: function(a: TSzArchive; index: LongWord;
    buf: Pointer; bufSize: QWord; written: PQWord): LongInt; cdecl;

  Sz_SetProgress: procedure(a: TSzArchive; cb: TSzProgressFunc; ctx: Pointer); cdecl;

  Sz_SetPassword: procedure(a: TSzArchive; utf8Password: PAnsiChar); cdecl;

  Sz_ExtractToStream: function(a: TSzArchive; index: LongWord;
    writeFn: TSzWriteFunc; ctx: Pointer): LongInt; cdecl;

  Sz_Close: procedure(a: TSzArchive); cdecl;

  Sz_ErrorString: function(code: LongInt): PAnsiChar; cdecl;

  { ---- Phase 2: creating .7z archives ---- }

  Sz_CreateArchive: function(utf8Path: PAnsiChar; level: LongInt; utf8Password: PAnsiChar): TSzWriter; cdecl;

  Sz_Writer_SetLevel: procedure(w: TSzWriter; level: LongInt); cdecl;

  Sz_Writer_SetPassword: procedure(w: TSzWriter; utf8Password: PAnsiChar); cdecl;

  Sz_AddFile: function(w: TSzWriter; utf8SrcPath, utf8NameInArchive: PAnsiChar): LongInt; cdecl;

  Sz_AddBuffer: function(w: TSzWriter; utf8NameInArchive: PAnsiChar;
    data: Pointer; len: QWord; mtimeUnix: Int64): LongInt; cdecl;

  Sz_AddEmptyDir: function(w: TSzWriter; utf8NameInArchive: PAnsiChar): LongInt; cdecl;

  Sz_Writer_AddStream: function(w: TSzWriter; utf8NameInArchive: PAnsiChar;
    size: QWord; mtimeUnix: Int64; readFn: TSzReadFunc; ctx: Pointer): LongInt; cdecl;

  Sz_Writer_SetProgress: procedure(w: TSzWriter; cb: TSzProgressFunc; ctx: Pointer); cdecl;

  { Encrypt archive headers (names/sizes) too; only effective with a password. }
  Sz_Writer_SetHeaderEncryption: procedure(w: TSzWriter; enable: LongInt); cdecl;

  Sz_FinishArchive: function(w: TSzWriter): LongInt; cdecl;

  Sz_FinishArchiveToFile: function(w: TSzWriter; utf8Path: PAnsiChar): LongInt; cdecl;

  Sz_FinishArchiveToStream: function(w: TSzWriter; writeFn: TSzWriteFunc;
    seekFn: TSzSeekFunc; ctx: Pointer): LongInt; cdecl;

  Sz_AbortArchive: procedure(w: TSzWriter); cdecl;

{$else}

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

{$endif}

{ ---- loading ---- }

{ True once the Sz_* entry points can be called.

  With SEVENZIPDYNAMIC this loads the library on the first call (and only
  then -- callers should invoke it right before they first need the library,
  not at program start) and binds every entry point; later calls just return
  the remembered result.  It never raises: on failure it returns False and
  puts the reason in SevenZipLibLoadError.  It is safe to call from several
  threads at once.

  Without SEVENZIPDYNAMIC the library is already bound by the OS loader and
  this simply returns True, so callers need no conditional code. }
function SevenZipLibAvailable: Boolean;

{ Reason the last load attempt failed; '' while no attempt has failed. }
var
  SevenZipLibLoadError: string = '';

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

uses
  SysUtils
{$ifdef SEVENZIPDYNAMIC}
  , SyncObjs, dynlibs
  {$ifndef MSWINDOWS}
  , dl
  {$endif}
{$endif}
  ;

{ ---------- loading ---------- }

{$ifdef SEVENZIPDYNAMIC}

var
  FLibHandle: TLibHandle = NilHandle;
  FLoadTried: Boolean = False;
  FLoadOk: Boolean = False;
  FLoadLock: TCriticalSection = nil;

{ Called once, under FLoadLock. }
function TryLoadSevenZipLib: Boolean;
var
  libpath: string;
  missing: string;

  procedure Bind(var AProc; const AName: AnsiString);
  begin
    Pointer(AProc) := GetProcedureAddress(FLibHandle, AName);
    if (Pointer(AProc) = nil) and (missing = '') then
      missing := AName;
  end;

begin
  Result := False;
  missing := '';

  { the library is deployed next to the program binary }
  libpath := ExtractFilePath(ParamStr(0)) + SevenZipLibName;
  if not FileExists(libpath) then
    libpath := SevenZipLibName;     { fall back to the loader's own search }

  {$ifdef MSWINDOWS}
  FLibHandle := LoadLibrary(libpath);
  {$else}
  FLibHandle := TLibHandle(dlopen(PAnsiChar(AnsiString(libpath)), RTLD_LAZY));
  {$endif}

  if FLibHandle = NilHandle then
  begin
    {$ifdef MSWINDOWS}
    SevenZipLibLoadError := 'cannot load ' + libpath +
      ': error ' + IntToStr(GetLastOSError);
    {$else}
    SevenZipLibLoadError := dlerror;
    if SevenZipLibLoadError = '' then
      SevenZipLibLoadError := 'dlopen failed for ' + libpath;
    {$endif}
    Exit;
  end;

  Bind(Sz_GlobalInit,                  'Sz_GlobalInit');
  Bind(Sz_VersionString,               'Sz_VersionString');
  Bind(Sz_OpenFile,                    'Sz_OpenFile');
  Bind(Sz_OpenFileEx,                  'Sz_OpenFileEx');
  Bind(Sz_OpenStream,                  'Sz_OpenStream');
  Bind(Sz_GetItemCount,                'Sz_GetItemCount');
  Bind(Sz_GetItemPath,                 'Sz_GetItemPath');
  Bind(Sz_GetItemInfo,                 'Sz_GetItemInfo');
  Bind(Sz_ExtractToFile,               'Sz_ExtractToFile');
  Bind(Sz_ExtractToBuffer,             'Sz_ExtractToBuffer');
  Bind(Sz_SetProgress,                 'Sz_SetProgress');
  Bind(Sz_SetPassword,                 'Sz_SetPassword');
  Bind(Sz_ExtractToStream,             'Sz_ExtractToStream');
  Bind(Sz_Close,                       'Sz_Close');
  Bind(Sz_ErrorString,                 'Sz_ErrorString');

  Bind(Sz_CreateArchive,               'Sz_CreateArchive');
  Bind(Sz_Writer_SetLevel,             'Sz_Writer_SetLevel');
  Bind(Sz_Writer_SetPassword,          'Sz_Writer_SetPassword');
  Bind(Sz_AddFile,                     'Sz_AddFile');
  Bind(Sz_AddBuffer,                   'Sz_AddBuffer');
  Bind(Sz_AddEmptyDir,                 'Sz_AddEmptyDir');
  Bind(Sz_Writer_AddStream,            'Sz_Writer_AddStream');
  Bind(Sz_Writer_SetProgress,          'Sz_Writer_SetProgress');
  Bind(Sz_Writer_SetHeaderEncryption,  'Sz_Writer_SetHeaderEncryption');
  Bind(Sz_FinishArchive,               'Sz_FinishArchive');
  Bind(Sz_FinishArchiveToFile,         'Sz_FinishArchiveToFile');
  Bind(Sz_FinishArchiveToStream,       'Sz_FinishArchiveToStream');
  Bind(Sz_AbortArchive,                'Sz_AbortArchive');

  if missing <> '' then
  begin
    SevenZipLibLoadError := libpath + ' does not export ' + missing +
      ' - wrong or outdated ' + SevenZipLibName;
    UnloadLibrary(FLibHandle);
    FLibHandle := NilHandle;
    Exit;
  end;

  SevenZipLibLoadError := '';
  Result := True;
end;

function SevenZipLibAvailable: Boolean;
begin
  { Always under the lock: it is called a handful of times per archive, never
    in a hot loop, and an unlocked fast path would let another thread see
    FLoadTried before the entry points it published. }
  FLoadLock.Acquire;
  try
    if not FLoadTried then
    begin
      FLoadTried := True;      { never retry a failed load on every archive }
      try
        FLoadOk := TryLoadSevenZipLib;
      except
        on E: Exception do
        begin
          FLoadOk := False;
          SevenZipLibLoadError := E.Message;
        end;
      end;
    end;
    Result := FLoadOk;
  finally
    FLoadLock.Release;
  end;
end;

{$else}

function SevenZipLibAvailable: Boolean;
begin
  { linked at build time, so the OS loader has already resolved everything }
  Result := True;
end;

{$endif}

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

{$ifdef SEVENZIPDYNAMIC}
initialization
  FLoadLock := TCriticalSection.Create;

finalization
  { the library itself is deliberately left loaded: other threads may still
    be inside it while units are being finalized }
  FreeAndNil(FLoadLock);
{$endif}

end.
