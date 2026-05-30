{ SevenZipClasses.pas -- higher-level T7zInArchive / T7zOutArchive classes on
  top of lib7za (SevenZipLib), to ease migration from the COM-based 7z.dll
  wrappers.

  This is NOT a drop-in for the COM unit -- it adapts the well-known class
  shapes to the flat lib7za API:
    * streams are FPC/Delphi TStream (not COM IInStream/ISequentialOutStream);
    * callbacks are plain (sender: Pointer; ...) procedures, not COM/stdcall;
    * only the .7z format is supported (lib7za = the "7za" code base);
    * some per-item metadata accepted for signature compatibility (Attributes,
      CreationTime, Comment, IsAnti) is not stored by the underlying library
      and is ignored -- size, name/path and modification time are honoured.

  Errors raise E7zException. Strings are UnicodeString at this layer and are
  converted to/from UTF-8 for the library.
}

unit SevenZipClasses;

{$mode objfpc}{$H+}

interface

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, SevenZipLib;

type
  E7zException = class(Exception);

{$IFNDEF WINDOWS}
  { Windows provides TFileTime; define a compatible record elsewhere so that
    code migrated from the COM wrapper keeps compiling. }
  TFileTime = record
    dwLowDateTime: LongWord;
    dwHighDateTime: LongWord;
  end;
{$ENDIF}

  { An item handle returned by the T7zOutArchive.Add* methods. With lib7za this
    is simply the zero-based index of the queued item. }
  T7zBatchItem = Cardinal;

  PCardArray = ^TCardArray;
  TCardArray = array[0 .. (MaxInt div SizeOf(Cardinal)) - 1] of Cardinal;

  { Return False from a progress callback to cancel the operation.
    When 'total' is True, 'value' is the total size; otherwise it is the number
    of bytes processed so far. }
  T7zProgressCallback = function(sender: Pointer; total: Boolean; value: Int64): Boolean;

  { Asked for a password on demand. Return True and fill 'password' to supply
    one, or False to abort. }
  T7zPasswordCallback = function(sender: Pointer; out password: UnicodeString): Boolean;

  { Supplies the destination stream for an item during batch extraction.
    Return True (with outStream set) to extract, or False to skip the item. }
  T7zGetStreamCallBack = function(sender: Pointer; index: Cardinal; var outStream: TStream): Boolean;

  { ---------------------------------------------------------------- }

  T7zInArchive = class
  private
    FHandle: TSzArchive;
    FStream: TStream;               // kept alive for OpenStream
    FPassword: UnicodeString;
    FHasPassword: Boolean;
    FPwSender: Pointer;
    FPwCallback: T7zPasswordCallback;
    FProgSender: Pointer;
    FProgCallback: T7zProgressCallback;
    FLastTotal: Int64;
    procedure NeedHandle;
    procedure ResolvePassword;
    procedure AttachCallbacks;
    function DoProgress(completed, total: QWord): LongInt;
    function GetNumberOfItems: Cardinal;
    function GetItemPath(const index: integer): UnicodeString;
    function GetItemName(const index: integer): UnicodeString;
    function GetItemSize(const index: integer): Int64;
    function GetItemIsFolder(const index: integer): boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OpenFile(const filename: string);
    procedure OpenStream(stream: TStream);
    procedure Close;
    procedure ExtractItem(const item: Cardinal; Stream: TStream; test: longbool);
    procedure ExtractItems(items: PCardArray; count: cardinal; test: longbool;
      sender: pointer; callback: T7zGetStreamCallBack);
    procedure ExtractAll(test: longbool; sender: pointer; callback: T7zGetStreamCallBack);
    procedure ExtractTo(const path: string);
    procedure SetPasswordCallback(sender: Pointer; callback: T7zPasswordCallback);
    procedure SetPassword(const password: UnicodeString);
    procedure SetProgressCallback(sender: Pointer; callback: T7zProgressCallback);
    property NumberOfItems: Cardinal read GetNumberOfItems;
    property ItemPath[const index: integer]: UnicodeString read GetItemPath;
    property ItemName[const index: integer]: UnicodeString read GetItemName;
    property ItemSize[const index: integer]: Int64 read GetItemSize;
    property ItemIsFolder[const index: integer]: boolean read GetItemIsFolder;
  end;

  { ---------------------------------------------------------------- }

  T7zOutArchive = class
  private
    FWriter: TSzWriter;
    FOwned: TList;                  // TStream instances we must Free
    FItemCount: Cardinal;
    FProgSender: Pointer;
    FProgCallback: T7zProgressCallback;
    FLastTotal: Int64;
    procedure NeedWriter;
    procedure NewWriter;
    function DoProgress(completed, total: QWord): LongInt;
    procedure FreeOwned;
    procedure SetEncryptHeaders(value: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
    function AddStream(Stream: TStream; Ownership: TStreamOwnership; Attributes: Cardinal;
      CreationTime, LastWriteTime: TFileTime; const Path: UnicodeString;
      IsFolder, IsAnti: boolean; const Comment: UnicodeString): T7zBatchItem;
    function AddString(const Text: string; Attributes: Cardinal;
      CreationTime, LastWriteTime: TFileTime; const Path: UnicodeString): T7zBatchItem;
    function AddFile(const Filename: TFileName; const Path: UnicodeString;
      const AFileSize: Int64; const ALastWriteTime, ACreationTime: TFileTime;
      const AnAttributes: Cardinal): T7zBatchItem;
    procedure AddFiles(const Dir, Path, Wildcard: string; recurse: boolean);
    procedure SaveToFile(const FileName: TFileName);
    procedure SaveToStream(stream: TStream);
    procedure SetProgressCallback(sender: Pointer; callback: T7zProgressCallback);
    procedure ClearBatch;
    procedure SetPassword(const password: UnicodeString);
    property EncryptHeaders: Boolean write SetEncryptHeaders;
  end;

implementation

{ ---------- conversions ---------- }

function ToUtf8(const s: UnicodeString): RawByteString;
begin
  Result := UTF8Encode(s);
end;

function FromUtf8(const s: RawByteString): UnicodeString;
begin
  Result := UTF8Decode(s);
end;

function FileTimeToUnix(const ft: TFileTime): Int64;
var
  q: QWord;
begin
  q := (QWord(ft.dwHighDateTime) shl 32) or QWord(ft.dwLowDateTime);
  if q < QWord(116444736000000000) then
    Result := 0
  else
    Result := Int64((q - QWord(116444736000000000)) div 10000000);
end;

procedure RaiseIf(rc: LongInt; const where: string);
begin
  if rc <> SZA_OK then
    raise E7zException.CreateFmt('%s: %s', [where, Sz_ErrorString(rc)]);
end;

{ ---------- cdecl trampolines (ctx -> object / TStream) ---------- }

function InProgressThunk(ctx: Pointer; completed, total: QWord): LongInt; cdecl;
begin
  Result := T7zInArchive(ctx).DoProgress(completed, total);
end;

function OutProgressThunk(ctx: Pointer; completed, total: QWord): LongInt; cdecl;
begin
  Result := T7zOutArchive(ctx).DoProgress(completed, total);
end;

function StreamReadThunk(ctx: Pointer; data: Pointer; size: LongWord;
  processed: PLongWord): LongInt; cdecl;
var
  n: LongInt;
begin
  try
    n := TStream(ctx).Read(PByte(data)^, size);
    if processed <> nil then processed^ := LongWord(n);
    Result := 0;
  except
    Result := 1;
  end;
end;

function StreamWriteThunk(ctx: Pointer; data: Pointer; size: LongWord;
  processed: PLongWord): LongInt; cdecl;
var
  n: LongInt;
begin
  try
    n := TStream(ctx).Write(PByte(data)^, size);
    if processed <> nil then processed^ := LongWord(n);
    if LongWord(n) = size then Result := 0 else Result := 1;
  except
    Result := 1;
  end;
end;

function StreamSeekThunk(ctx: Pointer; offset: Int64; origin: LongWord;
  newPos: PQWord): LongInt; cdecl;
var
  p: Int64;
begin
  try
    p := TStream(ctx).Seek(offset, TSeekOrigin(origin));
    if newPos <> nil then newPos^ := QWord(p);
    Result := 0;
  except
    Result := 1;
  end;
end;

function DiscardWriteThunk(ctx: Pointer; data: Pointer; size: LongWord;
  processed: PLongWord): LongInt; cdecl;
begin
  if processed <> nil then processed^ := size;  // pretend to consume everything
  Result := 0;
end;

{ ================= T7zInArchive ================= }

constructor T7zInArchive.Create;
begin
  inherited Create;
  FHandle := nil;
end;

destructor T7zInArchive.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure T7zInArchive.NeedHandle;
begin
  if FHandle = nil then
    raise E7zException.Create('archive is not open');
end;

function T7zInArchive.DoProgress(completed, total: QWord): LongInt;
begin
  Result := 0;
  if not Assigned(FProgCallback) then Exit;
  if Int64(total) <> FLastTotal then
  begin
    FLastTotal := Int64(total);
    if not FProgCallback(FProgSender, True, FLastTotal) then Exit(1);
  end;
  if not FProgCallback(FProgSender, False, Int64(completed)) then Result := 1;
end;

procedure T7zInArchive.AttachCallbacks;
begin
  FLastTotal := -1;
  if Assigned(FProgCallback) then
    Sz_SetProgress(FHandle, @InProgressThunk, Self)
  else
    Sz_SetProgress(FHandle, nil, nil);
end;

procedure T7zInArchive.ResolvePassword;
var
  pw: UnicodeString;
begin
  if (not FHasPassword) and Assigned(FPwCallback) then
  begin
    pw := '';
    if FPwCallback(FPwSender, pw) then
    begin
      FPassword := pw;
      FHasPassword := True;
    end;
  end;
end;

procedure T7zInArchive.OpenFile(const filename: string);
var
  err: LongInt;
  pwu: RawByteString;
  pwp: PAnsiChar;
begin
  Close;
  ResolvePassword;
  pwp := nil;
  if FHasPassword then begin pwu := ToUtf8(FPassword); pwp := PAnsiChar(pwu); end;
  err := 0;
  FHandle := Sz_OpenFileEx(PAnsiChar(ToUtf8(UnicodeString(filename))), pwp, @err);
  if FHandle = nil then
    raise E7zException.CreateFmt('OpenFile(%s): %s', [filename, Sz_ErrorString(err)]);
  AttachCallbacks;
end;

procedure T7zInArchive.OpenStream(stream: TStream);
var
  err: LongInt;
  pwu: RawByteString;
  pwp: PAnsiChar;
begin
  Close;
  ResolvePassword;
  pwp := nil;
  if FHasPassword then begin pwu := ToUtf8(FPassword); pwp := PAnsiChar(pwu); end;
  err := 0;
  FStream := stream;
  FHandle := Sz_OpenStream(@StreamReadThunk, @StreamSeekThunk, Pointer(stream), pwp, @err);
  if FHandle = nil then
  begin
    FStream := nil;
    raise E7zException.CreateFmt('OpenStream: %s', [Sz_ErrorString(err)]);
  end;
  AttachCallbacks;
end;

procedure T7zInArchive.Close;
begin
  if FHandle <> nil then
  begin
    Sz_Close(FHandle);
    FHandle := nil;
  end;
  FStream := nil;
end;

function T7zInArchive.GetNumberOfItems: Cardinal;
begin
  NeedHandle;
  Result := 0;
  Sz_GetItemCount(FHandle, Result);
end;

function T7zInArchive.GetItemPath(const index: integer): UnicodeString;
begin
  NeedHandle;
  Result := FromUtf8(Sz_ItemPath(FHandle, LongWord(index)));
end;

function T7zInArchive.GetItemName(const index: integer): UnicodeString;
var
  p: UnicodeString;
  i: integer;
begin
  p := GetItemPath(index);
  Result := p;
  for i := Length(p) downto 1 do
    if (p[i] = '/') or (p[i] = '\') then
    begin
      Result := Copy(p, i + 1, MaxInt);
      Break;
    end;
end;

function T7zInArchive.GetItemSize(const index: integer): Int64;
var
  sz: QWord;
begin
  NeedHandle;
  sz := 0;
  RaiseIf(Sz_GetItemInfo(FHandle, LongWord(index), @sz, nil, nil, nil, nil), 'GetItemSize');
  Result := Int64(sz);
end;

function T7zInArchive.GetItemIsFolder(const index: integer): boolean;
var
  isDir: LongInt;
begin
  NeedHandle;
  isDir := 0;
  RaiseIf(Sz_GetItemInfo(FHandle, LongWord(index), nil, @isDir, nil, nil, nil), 'GetItemIsFolder');
  Result := isDir <> 0;
end;

procedure T7zInArchive.ExtractItem(const item: Cardinal; Stream: TStream; test: longbool);
var
  rc: LongInt;
begin
  NeedHandle;
  if test then
    rc := Sz_ExtractToStream(FHandle, item, @DiscardWriteThunk, nil)
  else
  begin
    if Stream = nil then
      raise E7zException.Create('ExtractItem: Stream is nil');
    rc := Sz_ExtractToTStream(FHandle, item, Stream);
  end;
  RaiseIf(rc, 'ExtractItem');
end;

procedure T7zInArchive.ExtractItems(items: PCardArray; count: cardinal; test: longbool;
  sender: pointer; callback: T7zGetStreamCallBack);
var
  i: cardinal;
  idx: Cardinal;
  s: TStream;
begin
  NeedHandle;
  for i := 0 to count - 1 do
  begin
    idx := items^[i];
    s := nil;
    if Assigned(callback) and (not callback(sender, idx, s)) then
      Continue;
    if test then
      ExtractItem(idx, nil, True)
    else if s <> nil then
      ExtractItem(idx, s, False);
  end;
end;

procedure T7zInArchive.ExtractAll(test: longbool; sender: pointer; callback: T7zGetStreamCallBack);
var
  i, n: Cardinal;
  s: TStream;
begin
  n := GetNumberOfItems;
  for i := 0 to n - 1 do
  begin
    if GetItemIsFolder(integer(i)) then
      Continue;
    s := nil;
    if Assigned(callback) and (not callback(sender, i, s)) then
      Continue;
    if test then
      ExtractItem(i, nil, True)
    else if s <> nil then
      ExtractItem(i, s, False);
  end;
end;

procedure T7zInArchive.ExtractTo(const path: string);
var
  i, n: Cardinal;
  dest: UnicodeString;
  base: UnicodeString;
begin
  NeedHandle;
  base := UnicodeString(IncludeTrailingPathDelimiter(path));
  n := GetNumberOfItems;
  for i := 0 to n - 1 do
  begin
    dest := base + GetItemPath(integer(i));
    RaiseIf(Sz_ExtractToFile(FHandle, i, PAnsiChar(ToUtf8(dest))), 'ExtractTo');
  end;
end;

procedure T7zInArchive.SetPasswordCallback(sender: Pointer; callback: T7zPasswordCallback);
begin
  FPwSender := sender;
  FPwCallback := callback;
end;

procedure T7zInArchive.SetPassword(const password: UnicodeString);
begin
  FPassword := password;
  FHasPassword := password <> '';
  if FHandle <> nil then
    Sz_SetPassword(FHandle, PAnsiChar(ToUtf8(password)));
end;

procedure T7zInArchive.SetProgressCallback(sender: Pointer; callback: T7zProgressCallback);
begin
  FProgSender := sender;
  FProgCallback := callback;
  if FHandle <> nil then
    AttachCallbacks;
end;

{ ================= T7zOutArchive ================= }

constructor T7zOutArchive.Create;
begin
  inherited Create;
  FOwned := TList.Create;
  NewWriter;
end;

destructor T7zOutArchive.Destroy;
begin
  if FWriter <> nil then
    Sz_AbortArchive(FWriter);
  FWriter := nil;
  FreeOwned;
  FOwned.Free;
  inherited Destroy;
end;

procedure T7zOutArchive.NewWriter;
begin
  FWriter := Sz_CreateArchive(nil, 5, nil);   // path supplied at SaveTo*
  if FWriter = nil then
    raise E7zException.Create('cannot create archive writer');
  FItemCount := 0;
  if Assigned(FProgCallback) then
    Sz_Writer_SetProgress(FWriter, @OutProgressThunk, Self);
end;

procedure T7zOutArchive.NeedWriter;
begin
  if FWriter = nil then
    raise E7zException.Create('writer has already been saved; call ClearBatch to reuse');
end;

procedure T7zOutArchive.FreeOwned;
var
  i: integer;
begin
  for i := 0 to FOwned.Count - 1 do
    TStream(FOwned[i]).Free;
  FOwned.Clear;
end;

function T7zOutArchive.DoProgress(completed, total: QWord): LongInt;
begin
  Result := 0;
  if not Assigned(FProgCallback) then Exit;
  if Int64(total) <> FLastTotal then
  begin
    FLastTotal := Int64(total);
    if not FProgCallback(FProgSender, True, FLastTotal) then Exit(1);
  end;
  if not FProgCallback(FProgSender, False, Int64(completed)) then Result := 1;
end;

function T7zOutArchive.AddStream(Stream: TStream; Ownership: TStreamOwnership;
  Attributes: Cardinal; CreationTime, LastWriteTime: TFileTime; const Path: UnicodeString;
  IsFolder, IsAnti: boolean; const Comment: UnicodeString): T7zBatchItem;
begin
  NeedWriter;
  if IsFolder then
    RaiseIf(Sz_AddEmptyDir(FWriter, PAnsiChar(ToUtf8(Path))), 'AddStream(folder)')
  else
  begin
    Stream.Position := 0;
    RaiseIf(Sz_Writer_AddTStream(FWriter, ToUtf8(Path), Stream, FileTimeToUnix(LastWriteTime)),
      'AddStream');
    if Ownership = soOwned then
      FOwned.Add(Pointer(Stream));
  end;
  Result := FItemCount;
  Inc(FItemCount);
end;

function T7zOutArchive.AddString(const Text: string; Attributes: Cardinal;
  CreationTime, LastWriteTime: TFileTime; const Path: UnicodeString): T7zBatchItem;
var
  data: RawByteString;
begin
  NeedWriter;
  data := ToUtf8(UnicodeString(Text));
  if Length(data) > 0 then
    RaiseIf(Sz_AddBuffer(FWriter, PAnsiChar(ToUtf8(Path)), @data[1], QWord(Length(data)),
      FileTimeToUnix(LastWriteTime)), 'AddString')
  else
    RaiseIf(Sz_AddBuffer(FWriter, PAnsiChar(ToUtf8(Path)), nil, 0,
      FileTimeToUnix(LastWriteTime)), 'AddString');
  Result := FItemCount;
  Inc(FItemCount);
end;

function T7zOutArchive.AddFile(const Filename: TFileName; const Path: UnicodeString;
  const AFileSize: Int64; const ALastWriteTime, ACreationTime: TFileTime;
  const AnAttributes: Cardinal): T7zBatchItem;
begin
  NeedWriter;
  { lib7za reads size / times / attributes from disk itself }
  RaiseIf(Sz_AddFile(FWriter, PAnsiChar(ToUtf8(UnicodeString(Filename))),
    PAnsiChar(ToUtf8(Path))), 'AddFile');
  Result := FItemCount;
  Inc(FItemCount);
end;

procedure T7zOutArchive.AddFiles(const Dir, Path, Wildcard: string; recurse: boolean);
var
  baseDir, arcBase: string;

  procedure Walk(const curDir, curArc: string);
  var
    sr: TSearchRec;
  begin
    // files matching the wildcard
    if FindFirst(IncludeTrailingPathDelimiter(curDir) + Wildcard, faAnyFile, sr) = 0 then
    try
      repeat
        if (sr.Attr and faDirectory) = 0 then
          AddFile(IncludeTrailingPathDelimiter(curDir) + sr.Name,
            UnicodeString(curArc + sr.Name), 0, Default(TFileTime), Default(TFileTime), 0);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
    // sub-directories
    if recurse then
      if FindFirst(IncludeTrailingPathDelimiter(curDir) + '*', faDirectory, sr) = 0 then
      try
        repeat
          if ((sr.Attr and faDirectory) <> 0) and (sr.Name <> '.') and (sr.Name <> '..') then
            Walk(IncludeTrailingPathDelimiter(curDir) + sr.Name,
                 curArc + sr.Name + '/');
        until FindNext(sr) <> 0;
      finally
        FindClose(sr);
      end;
  end;

begin
  NeedWriter;
  baseDir := Dir;
  arcBase := Path;
  if (arcBase <> '') and (arcBase[Length(arcBase)] <> '/') and (arcBase[Length(arcBase)] <> '\') then
    arcBase := arcBase + '/';
  Walk(baseDir, arcBase);
end;

procedure T7zOutArchive.SaveToFile(const FileName: TFileName);
var
  rc: LongInt;
begin
  NeedWriter;
  FLastTotal := -1;
  rc := Sz_FinishArchiveToFile(FWriter, PAnsiChar(ToUtf8(UnicodeString(FileName))));
  FWriter := nil;   // freed by the library
  FreeOwned;
  RaiseIf(rc, 'SaveToFile');
end;

procedure T7zOutArchive.SaveToStream(stream: TStream);
var
  rc: LongInt;
begin
  NeedWriter;
  FLastTotal := -1;
  rc := Sz_FinishArchiveToStream(FWriter, @StreamWriteThunk, @StreamSeekThunk, Pointer(stream));
  FWriter := nil;
  FreeOwned;
  RaiseIf(rc, 'SaveToStream');
end;

procedure T7zOutArchive.SetProgressCallback(sender: Pointer; callback: T7zProgressCallback);
begin
  FProgSender := sender;
  FProgCallback := callback;
  if FWriter <> nil then
  begin
    if Assigned(callback) then
      Sz_Writer_SetProgress(FWriter, @OutProgressThunk, Self)
    else
      Sz_Writer_SetProgress(FWriter, nil, nil);
  end;
end;

procedure T7zOutArchive.ClearBatch;
begin
  if FWriter <> nil then
    Sz_AbortArchive(FWriter);
  FWriter := nil;
  FreeOwned;
  NewWriter;
end;

procedure T7zOutArchive.SetPassword(const password: UnicodeString);
begin
  NeedWriter;
  Sz_Writer_SetPassword(FWriter, PAnsiChar(ToUtf8(password)));
end;

procedure T7zOutArchive.SetEncryptHeaders(value: Boolean);
begin
  NeedWriter;
  if value then
    Sz_Writer_SetHeaderEncryption(FWriter, 1)
  else
    Sz_Writer_SetHeaderEncryption(FWriter, 0);
end;

end.
