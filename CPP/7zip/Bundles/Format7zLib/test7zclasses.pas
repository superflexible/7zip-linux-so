{ test7zclasses.pas -- self-contained Free Pascal test for the class API
  (SevenZipClasses: T7zInArchive / T7zOutArchive). No arguments: it builds
  archives in the current directory, exercises the classes, prints PASS/FAIL,
  cleans up, and exits non-zero on any failure.

  Build (from this directory, after building lib7za.so):
    fpc -Fu. -Fl./b/g_x64 -k'-rpath=$ORIGIN/b/g_x64' test7zclasses.pas
    ./test7zclasses

  Covers:
    * T7zOutArchive: AddString / AddStream(soOwned) / AddFile / AddFiles,
      SaveToFile, SaveToStream, SetProgressCallback, SetPassword, EncryptHeaders
    * T7zInArchive: OpenFile / OpenStream, item properties, ExtractItem (+ test),
      ExtractItems, ExtractAll (get-stream callback), ExtractTo, progress, cancel
}

program test7zclasses;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, SevenZipClasses;

const
  MAINARC  = 'selftest_cls.7z';
  ARC_ENC  = 'selftest_cls_enc.7z';
  ARC_HE   = 'selftest_cls_he.7z';
  ARC_CAN  = 'selftest_cls_cancel.7z';
  SRCDIR   = 'selftest_cls_dir';
  TMPFILE  = 'selftest_cls_file.bin';
  PASSWORD = 'hunter2';
  HELLO    = 'Hello from T7zOutArchive!';

var
  TotalChecks: Integer = 0;
  FailedChecks: Integer = 0;
  gProg: Integer = 0;

  { expectations: archive path -> content bytes }
  ExpNames: array of UnicodeString;
  ExpData : array of TBytes;

  { per-index destination streams for ExtractAll / ExtractItems callbacks }
  GStreams: array of TMemoryStream;

{ ---------- helpers ---------- }

procedure Check(const aName: string; cond: Boolean);
begin
  Inc(TotalChecks);
  if cond then WriteLn('  PASS  ', aName)
  else begin Inc(FailedChecks); WriteLn('  FAIL  ', aName); end;
end;

function MakeBytes(n: Integer; seed: LongWord): TBytes;
var i: Integer;
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
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size);
end;

procedure Expect(const aName: UnicodeString; const data: TBytes);
var i: Integer;
begin
  i := Length(ExpNames);
  SetLength(ExpNames, i + 1);
  SetLength(ExpData, i + 1);
  ExpNames[i] := aName;
  ExpData[i] := data;
end;

function ExpectedFor(const aName: UnicodeString; out data: TBytes): Boolean;
var i: Integer;
begin
  for i := 0 to High(ExpNames) do
    if ExpNames[i] = aName then
    begin
      data := ExpData[i];
      Exit(True);
    end;
  data := nil;
  Result := False;
end;

function IndexOf(arc: T7zInArchive; const wanted: UnicodeString): Integer;
var i: Integer;
begin
  Result := -1;
  for i := 0 to Integer(arc.NumberOfItems) - 1 do
    if arc.ItemPath[i] = wanted then Exit(i);
end;

function BytesStream(const data: TBytes): TBytesStream;
begin
  Result := TBytesStream.Create(data);
  Result.Position := 0;
end;

{ ---------- callbacks (plain functions) ---------- }

function ProgCB(sender: Pointer; total: Boolean; value: Int64): Boolean;
begin
  Inc(gProg);
  Result := True;     { continue }
end;

function CancelCB(sender: Pointer; total: Boolean; value: Int64): Boolean;
begin
  Result := False;    { cancel immediately }
end;

function GetStreamCB(sender: Pointer; index: Cardinal; var outStream: TStream): Boolean;
begin
  if GStreams[index] = nil then
    GStreams[index] := TMemoryStream.Create;
  outStream := GStreams[index];
  Result := True;
end;

{ ---------- setup of on-disk test data ---------- }

var
  HelloBytes, DataBytes, FileBytes, LargeBytes, LogA, LogB, LogC: TBytes;

procedure InitData;
var fs: TFileStream;
begin
  HelloBytes := BytesOf(HELLO);
  DataBytes  := MakeBytes(8 * 1024, 1);
  FileBytes  := MakeBytes(40 * 1024, 2);
  LargeBytes := MakeBytes(4 * 1024 * 1024, 3);
  LogA := MakeBytes(1000, 10);
  LogB := MakeBytes(2000, 11);
  LogC := MakeBytes(3000, 12);

  fs := TFileStream.Create(TMPFILE, fmCreate);
  try fs.WriteBuffer(FileBytes[0], Length(FileBytes)); finally fs.Free; end;

  ForceDirectories(SRCDIR);
  ForceDirectories(SRCDIR + PathDelim + 'sub');
  fs := TFileStream.Create(SRCDIR + PathDelim + 'a.log', fmCreate);
  try fs.WriteBuffer(LogA[0], Length(LogA)); finally fs.Free; end;
  fs := TFileStream.Create(SRCDIR + PathDelim + 'b.log', fmCreate);
  try fs.WriteBuffer(LogB[0], Length(LogB)); finally fs.Free; end;
  fs := TFileStream.Create(SRCDIR + PathDelim + 'sub' + PathDelim + 'c.log', fmCreate);
  try fs.WriteBuffer(LogC[0], Length(LogC)); finally fs.Free; end;

  Expect('hello.txt', HelloBytes);
  Expect('data.bin', DataBytes);
  Expect('file.bin', FileBytes);
  Expect('large.bin', LargeBytes);
  Expect('logs/a.log', LogA);
  Expect('logs/b.log', LogB);
  Expect('logs/sub/c.log', LogC);
end;

{ ---------- tests ---------- }

procedure TestCreate;
var outa: T7zOutArchive;
begin
  WriteLn('[T7zOutArchive: build + SaveToFile with progress]');
  gProg := 0;
  outa := T7zOutArchive.Create;
  try
    outa.SetProgressCallback(nil, @ProgCB);
    outa.AddString(HELLO, 0, Default(TFileTime), Default(TFileTime), 'hello.txt');
    outa.AddStream(BytesStream(DataBytes), soOwned, 0,
      Default(TFileTime), Default(TFileTime), 'data.bin', False, False, '');
    outa.AddStream(BytesStream(LargeBytes), soOwned, 0,
      Default(TFileTime), Default(TFileTime), 'large.bin', False, False, '');
    outa.AddFile(TMPFILE, 'file.bin', 0, Default(TFileTime), Default(TFileTime), 0);
    outa.AddFiles(SRCDIR, 'logs', '*.log', True);
    outa.SaveToFile(MAINARC);
    Check('SaveToFile', FileExists(MAINARC));
    Check('out progress fired', gProg > 0);
  finally
    outa.Free;
  end;
end;

procedure VerifyItem(arc: T7zInArchive; const aName: UnicodeString);
var idx: Integer; ms: TMemoryStream; exp: TBytes;
begin
  if not ExpectedFor(aName, exp) then begin Check('expected ' + string(aName), False); Exit; end;
  idx := IndexOf(arc, aName);
  if idx < 0 then begin Check('find ' + string(aName), False); Exit; end;
  ms := TMemoryStream.Create;
  try
    try
      arc.ExtractItem(Cardinal(idx), ms, False);
      Check('ExtractItem+verify ' + string(aName),
        BytesEqual(StreamToBytes(ms), exp) and (arc.ItemSize[idx] = Length(exp)));
    except
      on E: Exception do Check('ExtractItem ' + string(aName) + ' (' + E.Message + ')', False);
    end;
  finally
    ms.Free;
  end;
end;

procedure TestOpenAndExtract;
var arc: T7zInArchive; i: Integer;
begin
  WriteLn('[T7zInArchive: OpenFile + item properties + ExtractItem]');
  arc := T7zInArchive.Create;
  try
    arc.OpenFile(MAINARC);
    Check('NumberOfItems = 7', arc.NumberOfItems = 7);
    for i := 0 to High(ExpNames) do
      VerifyItem(arc, ExpNames[i]);
    { property sanity on one item }
    i := IndexOf(arc, 'logs/sub/c.log');
    Check('ItemName of logs/sub/c.log', (i >= 0) and (arc.ItemName[i] = 'c.log'));
    Check('ItemIsFolder = false for a file', (i >= 0) and (not arc.ItemIsFolder[i]));
  finally
    arc.Free;
  end;
end;

procedure TestExtractAll;
var arc: T7zInArchive; i, n: Integer; exp: TBytes; nm: UnicodeString;
begin
  WriteLn('[ExtractAll with get-stream callback]');
  arc := T7zInArchive.Create;
  try
    arc.OpenFile(MAINARC);
    n := Integer(arc.NumberOfItems);
    SetLength(GStreams, n);
    for i := 0 to n - 1 do GStreams[i] := nil;
    arc.ExtractAll(False, nil, @GetStreamCB);
    for i := 0 to n - 1 do
    begin
      if arc.ItemIsFolder[i] then Continue;
      nm := arc.ItemPath[i];
      if ExpectedFor(nm, exp) and (GStreams[i] <> nil) then
        Check('ExtractAll ' + string(nm), BytesEqual(StreamToBytes(GStreams[i]), exp))
      else
        Check('ExtractAll ' + string(nm), False);
    end;
    for i := 0 to n - 1 do GStreams[i].Free;
    SetLength(GStreams, 0);
  finally
    arc.Free;
  end;
end;

procedure TestExtractItemsSubsetAndTest;
var arc: T7zInArchive; n: Integer; sel: array[0..1] of Cardinal; ms: TMemoryStream;
begin
  WriteLn('[ExtractItems subset + test mode]');
  arc := T7zInArchive.Create;
  try
    arc.OpenFile(MAINARC);
    n := Integer(arc.NumberOfItems);
    SetLength(GStreams, n);   { dynamic array elements are nil-initialised }
    sel[0] := Cardinal(IndexOf(arc, 'hello.txt'));
    sel[1] := Cardinal(IndexOf(arc, 'file.bin'));
    arc.ExtractItems(PCardArray(@sel[0]), 2, False, nil, @GetStreamCB);
    Check('ExtractItems hello.txt', (GStreams[sel[0]] <> nil) and
      BytesEqual(StreamToBytes(GStreams[sel[0]]), HelloBytes));
    Check('ExtractItems file.bin', (GStreams[sel[1]] <> nil) and
      BytesEqual(StreamToBytes(GStreams[sel[1]]), FileBytes));
    GStreams[sel[0]].Free; GStreams[sel[1]].Free;
    SetLength(GStreams, 0);

    { test mode: must succeed without writing anywhere }
    ms := TMemoryStream.Create;
    try
      arc.ExtractItem(Cardinal(IndexOf(arc, 'large.bin')), ms, True); { test=True }
      Check('ExtractItem test mode (no exception, nothing written)', ms.Size = 0);
    except
      on E: Exception do Check('ExtractItem test mode (' + E.Message + ')', False);
    end;
    ms.Free;
  finally
    arc.Free;
  end;
end;

procedure TestExtractTo;
var arc: T7zInArchive; got: TBytes;
  procedure CheckFile(const rel: string; const exp: TBytes);
  var fs: TFileStream;
  begin
    if not FileExists('outdir' + PathDelim + rel) then
    begin Check('ExtractTo ' + rel, False); Exit; end;
    fs := TFileStream.Create('outdir' + PathDelim + rel, fmOpenRead);
    try got := StreamToBytes(fs); finally fs.Free; end;
    Check('ExtractTo ' + rel, BytesEqual(got, exp));
  end;
begin
  WriteLn('[ExtractTo folder]');
  arc := T7zInArchive.Create;
  try
    arc.OpenFile(MAINARC);
    arc.ExtractTo('outdir');
  finally
    arc.Free;
  end;
  CheckFile('hello.txt', HelloBytes);
  CheckFile('logs' + PathDelim + 'sub' + PathDelim + 'c.log', LogC);
end;

procedure TestSaveToStreamOpenStream;
var outa: T7zOutArchive; arc: T7zInArchive; ms: TMemoryStream; idx: Integer;
  vs: TMemoryStream;
begin
  WriteLn('[SaveToStream + OpenStream round-trip]');
  ms := TMemoryStream.Create;
  outa := T7zOutArchive.Create;
  try
    outa.AddString(HELLO, 0, Default(TFileTime), Default(TFileTime), 'hello.txt');
    outa.AddStream(BytesStream(DataBytes), soOwned, 0,
      Default(TFileTime), Default(TFileTime), 'data.bin', False, False, '');
    outa.SaveToStream(ms);
  finally
    outa.Free;
  end;
  Check('SaveToStream produced data', ms.Size > 0);

  ms.Position := 0;
  arc := T7zInArchive.Create;
  try
    arc.OpenStream(ms);            { ms must stay alive until Close }
    Check('OpenStream item count = 2', arc.NumberOfItems = 2);
    idx := IndexOf(arc, 'data.bin');
    vs := TMemoryStream.Create;
    try
      arc.ExtractItem(Cardinal(idx), vs, False);
      Check('OpenStream extract data.bin', BytesEqual(StreamToBytes(vs), DataBytes));
    finally
      vs.Free;
    end;
    arc.Close;
  finally
    arc.Free;
  end;
  ms.Free;
end;

procedure TestExtractProgress;
var arc: T7zInArchive; ms: TMemoryStream;
begin
  WriteLn('[extraction progress via class]');
  arc := T7zInArchive.Create;
  try
    gProg := 0;
    arc.SetProgressCallback(nil, @ProgCB);
    arc.OpenFile(MAINARC);
    ms := TMemoryStream.Create;
    try
      arc.ExtractItem(Cardinal(IndexOf(arc, 'large.bin')), ms, False);
    finally
      ms.Free;
    end;
    Check('in progress fired', gProg > 0);
  finally
    arc.Free;
  end;
end;

procedure TestCancel;
var outa: T7zOutArchive; cancelled: Boolean;
begin
  WriteLn('[cancel during SaveToFile via class]');
  cancelled := False;
  outa := T7zOutArchive.Create;
  try
    outa.SetProgressCallback(nil, @CancelCB);
    outa.AddStream(BytesStream(LargeBytes), soOwned, 0,
      Default(TFileTime), Default(TFileTime), 'large.bin', False, False, '');
    try
      outa.SaveToFile(ARC_CAN);
    except
      on E7zException do cancelled := True;
    end;
    Check('SaveToFile raised on cancel', cancelled);
  finally
    outa.Free;
  end;
  if FileExists(ARC_CAN) then DeleteFile(ARC_CAN);
end;

procedure TestEncryption;
var outa: T7zOutArchive; arc: T7zInArchive; ms: TMemoryStream; rejected: Boolean;
begin
  WriteLn('[encryption + header encryption via class]');

  { content encryption }
  outa := T7zOutArchive.Create;
  try
    outa.SetPassword(PASSWORD);
    outa.AddString(HELLO, 0, Default(TFileTime), Default(TFileTime), 'secret.txt');
    outa.SaveToFile(ARC_ENC);
  finally
    outa.Free;
  end;

  arc := T7zInArchive.Create;
  try
    arc.SetPassword(PASSWORD);
    arc.OpenFile(ARC_ENC);
    ms := TMemoryStream.Create;
    try
      arc.ExtractItem(Cardinal(IndexOf(arc, 'secret.txt')), ms, False);
      Check('decrypt with password', BytesEqual(StreamToBytes(ms), HelloBytes));
    finally
      ms.Free;
    end;
  finally
    arc.Free;
  end;

  { no password -> extraction must fail }
  arc := T7zInArchive.Create;
  try
    arc.OpenFile(ARC_ENC);
    ms := TMemoryStream.Create;
    rejected := False;
    try
      try arc.ExtractItem(Cardinal(IndexOf(arc, 'secret.txt')), ms, False);
      except on E7zException do rejected := True; end;
      Check('extraction without password rejected', rejected);
    finally
      ms.Free;
    end;
  finally
    arc.Free;
  end;

  { header encryption -> cannot even open without password }
  outa := T7zOutArchive.Create;
  try
    outa.SetPassword(PASSWORD);
    outa.EncryptHeaders := True;
    outa.AddString(HELLO, 0, Default(TFileTime), Default(TFileTime), 'secret.txt');
    outa.SaveToFile(ARC_HE);
  finally
    outa.Free;
  end;

  arc := T7zInArchive.Create;
  try
    rejected := False;
    try arc.OpenFile(ARC_HE);
    except on E7zException do rejected := True; end;
    Check('open header-encrypted without password fails', rejected);
  finally
    arc.Free;
  end;
end;

procedure Cleanup;
  procedure Del(const fn: string); begin if FileExists(fn) then DeleteFile(fn); end;
begin
  Del(MAINARC); Del(ARC_ENC); Del(ARC_HE); Del(ARC_CAN); Del(TMPFILE);
  Del(SRCDIR + PathDelim + 'a.log');
  Del(SRCDIR + PathDelim + 'b.log');
  Del(SRCDIR + PathDelim + 'sub' + PathDelim + 'c.log');
  RemoveDir(SRCDIR + PathDelim + 'sub');
  RemoveDir(SRCDIR);
  { extracted tree }
  Del('outdir' + PathDelim + 'hello.txt');
  Del('outdir' + PathDelim + 'data.bin');
  Del('outdir' + PathDelim + 'file.bin');
  Del('outdir' + PathDelim + 'large.bin');
  Del('outdir' + PathDelim + 'logs' + PathDelim + 'a.log');
  Del('outdir' + PathDelim + 'logs' + PathDelim + 'b.log');
  Del('outdir' + PathDelim + 'logs' + PathDelim + 'sub' + PathDelim + 'c.log');
  RemoveDir('outdir' + PathDelim + 'logs' + PathDelim + 'sub');
  RemoveDir('outdir' + PathDelim + 'logs');
  RemoveDir('outdir');
end;

begin
  WriteLn('lib7za class self-test');
  WriteLn;
  InitData;
  try
    TestCreate;
    TestOpenAndExtract;
    TestExtractAll;
    TestExtractItemsSubsetAndTest;
    TestExtractTo;
    TestSaveToStreamOpenStream;
    TestExtractProgress;
    TestCancel;
    TestEncryption;
  finally
    Cleanup;
  end;

  WriteLn;
  WriteLn(Format('%d checks, %d failed', [TotalChecks, FailedChecks]));
  if FailedChecks = 0 then
  begin WriteLn('ALL TESTS PASSED'); Halt(0); end
  else
  begin WriteLn('SOME TESTS FAILED'); Halt(1); end;
end.
