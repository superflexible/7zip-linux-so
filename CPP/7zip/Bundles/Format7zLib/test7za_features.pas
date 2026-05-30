{ test7za_features.pas -- self-contained Free Pascal test for the lib7za
  progress / streaming features. Takes no arguments: it creates archives in the
  current directory, exercises each feature, prints PASS/FAIL per check, then
  cleans up and exits non-zero if anything failed.

  Build (from this directory, after building lib7za.so):
    fpc -Fu. -Fl./b/g_x64 -k'-rpath=$ORIGIN/b/g_x64' test7za_features.pas
    ./test7za_features

  Covers:
    * Sz_Writer_AddTStream  (add an item from a TStream)
    * Sz_ExtractToTStream   (extract an item into a TStream)
    * Sz_Writer_SetProgress / Sz_SetProgress (progress callbacks)
    * cancellation via a progress callback (-> SZA_ERR_CANCELLED)
    * AES round-trip + wrong-password rejection
}

program test7za_features;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, SevenZipLib;

const
  ARC      = 'selftest.7z';
  ARC_ENC  = 'selftest_enc.7z';
  ARC_HE   = 'selftest_he.7z';
  ARC_CAN  = 'selftest_cancel.7z';
  TMPFILE  = 'selftest_src.bin';
  PASSWORD = 'hunter2';

var
  TotalChecks: Integer = 0;
  FailedChecks: Integer = 0;

  { progress bookkeeping (callbacks are plain cdecl functions -> use globals) }
  gProgressCalls: Integer = 0;

{ ---------- helpers ---------- }

procedure Check(const aName: string; cond: Boolean);
begin
  Inc(TotalChecks);
  if cond then
    WriteLn('  PASS  ', aName)
  else
  begin
    Inc(FailedChecks);
    WriteLn('  FAIL  ', aName);
  end;
end;

{ deterministic pseudo-random bytes (LCG) so results are reproducible }
function MakeBytes(n: Integer; seed: LongWord): TBytes;
var
  i: Integer;
begin
  Result := nil;
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    seed := seed * 1103515245 + 12345;
    Result[i] := Byte(seed shr 16);
  end;
end;

function BytesEqual(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and
            ((Length(a) = 0) or (CompareByte(a[0], b[0], Length(a)) = 0));
end;

function StreamToBytes(s: TStream): TBytes;
begin
  Result := nil;
  SetLength(Result, s.Size);
  s.Position := 0;
  if s.Size > 0 then
    s.ReadBuffer(Result[0], s.Size);
end;

{ ---------- progress callbacks ---------- }

function CountingProgress(ctx: Pointer; completed, total: QWord): LongInt; cdecl;
begin
  Inc(gProgressCalls);
  Result := 0; { keep going }
end;

function CancellingProgress(ctx: Pointer; completed, total: QWord): LongInt; cdecl;
begin
  Inc(gProgressCalls);
  Result := 1; { cancel on the very first report }
end;

{ ---------- test data ---------- }

var
  HelloBytes, BufferBytes, FileBytes, LargeBytes: TBytes;

procedure InitData;
var
  fs: TFileStream;
begin
  HelloBytes  := BytesOf('Hello, 7-Zip from Free Pascal!'#10);
  BufferBytes := MakeBytes(4 * 1024, 1);
  FileBytes   := MakeBytes(64 * 1024, 2);
  LargeBytes  := MakeBytes(8 * 1024 * 1024, 3); { big + incompressible -> progress fires }

  fs := TFileStream.Create(TMPFILE, fmCreate);
  try
    fs.WriteBuffer(FileBytes[0], Length(FileBytes));
  finally
    fs.Free;
  end;
end;

{ ---------- tests ---------- }

procedure TestCreate;
var
  w: TSzWriter;
  helloStrm, largeStrm: TBytesStream;
  rc: LongInt;
begin
  WriteLn('[create archive: AddTStream / AddBuffer / AddFile + progress]');
  gProgressCalls := 0;

  w := Sz_CreateArchive(PAnsiChar(ARC), 5, nil);
  Check('Sz_CreateArchive', w <> nil);
  if w = nil then Exit;

  Sz_Writer_SetProgress(w, @CountingProgress, nil);

  helloStrm := TBytesStream.Create(HelloBytes);
  largeStrm := TBytesStream.Create(LargeBytes);
  try
    helloStrm.Position := 0;
    largeStrm.Position := 0;
    Check('AddTStream hello.txt',
      Sz_Writer_AddTStream(w, 'hello.txt', helloStrm) = SZA_OK);
    Check('AddBuffer frombuffer.bin',
      Sz_AddBuffer(w, 'frombuffer.bin', @BufferBytes[0], Length(BufferBytes), 0) = SZA_OK);
    Check('AddFile fromfile.bin',
      Sz_AddFile(w, PAnsiChar(TMPFILE), 'fromfile.bin') = SZA_OK);
    Check('AddTStream large.bin',
      Sz_Writer_AddTStream(w, 'large.bin', largeStrm) = SZA_OK);

    rc := Sz_FinishArchive(w);   { reads the streams now; frees the writer }
    Check('Sz_FinishArchive', rc = SZA_OK);
  finally
    helloStrm.Free;
    largeStrm.Free;
  end;

  Check('creation progress callback fired', gProgressCalls > 0);
  Check('archive file exists', FileExists(ARC));
end;

{ find an item index by its archive path }
function IndexOf(a: TSzArchive; const wanted: UTF8String): LongInt;
var
  i, n: LongWord;
begin
  Result := -1;
  n := 0;
  Sz_GetItemCount(a, n);
  for i := 0 to n - 1 do
    if Sz_ItemPath(a, i) = wanted then
      Exit(LongInt(i));
end;

procedure VerifyItem(a: TSzArchive; const aName: UTF8String; const expected: TBytes);
var
  idx: LongInt;
  ms: TMemoryStream;
begin
  idx := IndexOf(a, aName);
  if idx < 0 then
  begin
    Check('extract ' + aName + ' (found)', False);
    Exit;
  end;
  ms := TMemoryStream.Create;
  try
    if Sz_ExtractToTStream(a, LongWord(idx), ms) = SZA_OK then
      Check('extract+verify ' + aName, BytesEqual(StreamToBytes(ms), expected))
    else
      Check('extract+verify ' + aName, False);
  finally
    ms.Free;
  end;
end;

procedure TestExtract;
var
  a: TSzArchive;
  n: LongWord;
begin
  WriteLn('[open + ExtractToTStream round-trip]');
  a := Sz_OpenFile(PAnsiChar(ARC), nil);
  Check('Sz_OpenFile', a <> nil);
  if a = nil then Exit;
  try
    n := 0;
    Sz_GetItemCount(a, n);
    Check('item count = 4', n = 4);

    VerifyItem(a, 'hello.txt', HelloBytes);
    VerifyItem(a, 'frombuffer.bin', BufferBytes);
    VerifyItem(a, 'fromfile.bin', FileBytes);
    VerifyItem(a, 'large.bin', LargeBytes);
  finally
    Sz_Close(a);
  end;
end;

procedure TestExtractProgress;
var
  a: TSzArchive;
  idx: LongInt;
  ms: TMemoryStream;
begin
  WriteLn('[extraction progress callback]');
  a := Sz_OpenFile(PAnsiChar(ARC), nil);
  if a = nil then begin Check('open for progress', False); Exit; end;
  try
    gProgressCalls := 0;
    Sz_SetProgress(a, @CountingProgress, nil);
    idx := IndexOf(a, 'large.bin');
    ms := TMemoryStream.Create;
    try
      Check('extract large.bin (with progress)',
        Sz_ExtractToTStream(a, LongWord(idx), ms) = SZA_OK);
    finally
      ms.Free;
    end;
    Check('extraction progress callback fired', gProgressCalls > 0);
  finally
    Sz_Close(a);
  end;
end;

procedure TestCancelCreate;
var
  w: TSzWriter;
  largeStrm: TBytesStream;
  rc: LongInt;
begin
  WriteLn('[cancel during creation]');
  gProgressCalls := 0;
  w := Sz_CreateArchive(PAnsiChar(ARC_CAN), 9, nil);
  if w = nil then begin Check('create (cancel test)', False); Exit; end;
  Sz_Writer_SetProgress(w, @CancellingProgress, nil);
  largeStrm := TBytesStream.Create(LargeBytes);
  try
    largeStrm.Position := 0;
    Sz_Writer_AddTStream(w, 'large.bin', largeStrm);
    rc := Sz_FinishArchive(w);
    Check('FinishArchive returns SZA_ERR_CANCELLED', rc = SZA_ERR_CANCELLED);
  finally
    largeStrm.Free;
  end;
  if FileExists(ARC_CAN) then
    DeleteFile(ARC_CAN);
end;

procedure TestCancelExtract;
var
  a: TSzArchive;
  idx: LongInt;
  ms: TMemoryStream;
begin
  WriteLn('[cancel during extraction]');
  a := Sz_OpenFile(PAnsiChar(ARC), nil);
  if a = nil then begin Check('open (cancel extract)', False); Exit; end;
  try
    gProgressCalls := 0;
    Sz_SetProgress(a, @CancellingProgress, nil);
    idx := IndexOf(a, 'large.bin');
    ms := TMemoryStream.Create;
    try
      Check('ExtractToTStream returns SZA_ERR_CANCELLED',
        Sz_ExtractToTStream(a, LongWord(idx), ms) = SZA_ERR_CANCELLED);
    finally
      ms.Free;
    end;
  finally
    Sz_Close(a);
  end;
end;

procedure TestEncryption;
var
  w: TSzWriter;
  helloStrm: TBytesStream;
  a: TSzArchive;
  idx: LongInt;
  ms: TMemoryStream;
begin
  WriteLn('[encrypted round-trip + wrong password]');
  w := Sz_CreateArchive(PAnsiChar(ARC_ENC), 5, PAnsiChar(PASSWORD));
  if w = nil then begin Check('create encrypted', False); Exit; end;
  helloStrm := TBytesStream.Create(HelloBytes);
  try
    helloStrm.Position := 0;
    Sz_Writer_AddTStream(w, 'secret.txt', helloStrm);
    Check('finish encrypted', Sz_FinishArchive(w) = SZA_OK);
  finally
    helloStrm.Free;
  end;

  { correct password }
  a := Sz_OpenFile(PAnsiChar(ARC_ENC), PAnsiChar(PASSWORD));
  if a <> nil then
  try
    idx := IndexOf(a, 'secret.txt');
    ms := TMemoryStream.Create;
    try
      if (idx >= 0) and (Sz_ExtractToTStream(a, LongWord(idx), ms) = SZA_OK) then
        Check('decrypt with correct password', BytesEqual(StreamToBytes(ms), HelloBytes))
      else
        Check('decrypt with correct password', False);
    finally
      ms.Free;
    end;
  finally
    Sz_Close(a);
  end
  else
    Check('open encrypted (correct password)', False);

  { no password -> headers open, but content extraction must fail }
  a := Sz_OpenFile(PAnsiChar(ARC_ENC), nil);
  if a <> nil then
  try
    idx := IndexOf(a, 'secret.txt');
    ms := TMemoryStream.Create;
    try
      Check('extraction without password is rejected',
        (idx < 0) or (Sz_ExtractToTStream(a, LongWord(idx), ms) <> SZA_OK));
    finally
      ms.Free;
    end;
  finally
    Sz_Close(a);
  end
  else
    Check('extraction without password is rejected', True); { open itself failed = fine }
end;

procedure TestHeaderEncryption;
var
  w: TSzWriter;
  helloStrm: TBytesStream;
  a: TSzArchive;
  n: LongWord;
begin
  WriteLn('[header encryption]');
  w := Sz_CreateArchive(PAnsiChar(ARC_HE), 5, PAnsiChar(PASSWORD));
  if w = nil then begin Check('create header-encrypted', False); Exit; end;
  Sz_Writer_SetHeaderEncryption(w, 1);
  helloStrm := TBytesStream.Create(HelloBytes);
  try
    helloStrm.Position := 0;
    Sz_Writer_AddTStream(w, 'secret.txt', helloStrm);
    Check('finish header-encrypted', Sz_FinishArchive(w) = SZA_OK);
  finally
    helloStrm.Free;
  end;

  { without a password the headers can't even be read -> open must fail }
  a := Sz_OpenFile(PAnsiChar(ARC_HE), nil);
  Check('open without password fails (headers encrypted)', a = nil);
  if a <> nil then Sz_Close(a);

  { with the password, listing works }
  a := Sz_OpenFile(PAnsiChar(ARC_HE), PAnsiChar(PASSWORD));
  Check('open header-encrypted with password', a <> nil);
  if a <> nil then
  try
    n := 0;
    Sz_GetItemCount(a, n);
    Check('header-encrypted item count = 1', n = 1);
  finally
    Sz_Close(a);
  end;
end;

procedure Cleanup;
begin
  if FileExists(ARC) then DeleteFile(ARC);
  if FileExists(ARC_ENC) then DeleteFile(ARC_ENC);
  if FileExists(ARC_HE) then DeleteFile(ARC_HE);
  if FileExists(ARC_CAN) then DeleteFile(ARC_CAN);
  if FileExists(TMPFILE) then DeleteFile(TMPFILE);
end;

begin
  Sz_GlobalInit;
  WriteLn('lib7za feature self-test (', Sz_VersionString, ')');
  WriteLn;

  InitData;
  try
    TestCreate;
    TestExtract;
    TestExtractProgress;
    TestCancelCreate;
    TestCancelExtract;
    TestEncryption;
    TestHeaderEncryption;
  finally
    Cleanup;
  end;

  WriteLn;
  WriteLn(Format('%d checks, %d failed', [TotalChecks, FailedChecks]));
  if FailedChecks = 0 then
  begin
    WriteLn('ALL TESTS PASSED');
    Halt(0);
  end
  else
  begin
    WriteLn('SOME TESTS FAILED');
    Halt(1);
  end;
end.
