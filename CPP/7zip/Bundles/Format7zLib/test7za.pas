{ test7za.pas -- Free Pascal command-line test driver for lib7za.

  Exercises the flat C wrapper (SevenZipLib.pas): list, extract (to disk and to
  memory) and create .7z archives.

  Build (from this directory, with the shared library already built):
    Linux:
      fpc -Fu. -k'-rpath=$ORIGIN/b/g_x64' -Fl./b/g_x64 test7za.pas
    macOS:
      fpc -Fu. -k'-rpath' -k'@executable_path/b/m_arm64' -Fl./b/m_arm64 test7za.pas
    (or just make sure lib7za.so / lib7za.dylib is on the loader search path,
     e.g. via LD_LIBRARY_PATH / DYLD_LIBRARY_PATH, and drop the -k/-Fl flags.)

  Usage:
    test7za l  <archive.7z> [password]            list contents
    test7za x  <archive.7z> <destdir> [password]  extract all to destdir
    test7za xb <archive.7z> <index> [password]    extract one item to memory
    test7za c  <out.7z> <file> [file ...]         create archive (level 5)
    test7za cp <password> <out.7z> <file> [...]   create encrypted archive
}

program test7za;

{$mode objfpc}{$H+}

uses
  SysUtils, DateUtils, SevenZipLib;

procedure Die(const msg: string);
begin
  WriteLn(StdErr, 'error: ', msg);
  Halt(1);
end;

function FmtTime(mtimeUnix: Int64): string;
begin
  if mtimeUnix <= 0 then
    Result := '                   '
  else
    Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', UnixToDateTime(mtimeUnix));
end;

{ ---- list ---- }
procedure CmdList(const archive, password: string);
var
  a: TSzArchive;
  err, isDir, crcDef: LongInt;
  i, n: LongWord;
  size: QWord;
  mtime: Int64;
  crc: LongWord;
  pw: PAnsiChar;
begin
  if password <> '' then pw := PAnsiChar(password) else pw := nil;
  a := Sz_OpenFileEx(PAnsiChar(archive), pw, @err);
  if a = nil then
    Die('open: ' + Sz_ErrorString(err));
  try
    n := 0;
    Sz_GetItemCount(a, n);
    WriteLn(Format('%d item(s) in %s', [n, archive]));
    WriteLn('   Date      Time     Attr        Size   CRC32     Name');
    WriteLn('------------------- ----- ------------ -------- ------------------------');
    for i := 0 to n - 1 do
    begin
      size := 0; isDir := 0; mtime := 0; crc := 0; crcDef := 0;
      Sz_GetItemInfo(a, i, @size, @isDir, @mtime, @crc, @crcDef);
      Write(FmtTime(mtime), ' ');
      if isDir <> 0 then Write('D    ') else Write('.    ');
      Write(Format('%12d ', [size]));
      if crcDef <> 0 then Write(Format('%.8x ', [crc])) else Write('         ');
      WriteLn(Sz_ItemPath(a, i));
    end;
  finally
    Sz_Close(a);
  end;
end;

{ ---- extract all to disk ---- }
procedure CmdExtract(const archive, destDir, password: string);
var
  a: TSzArchive;
  err, isDir, r: LongInt;
  i, n: LongWord;
  size: QWord;
  pw: PAnsiChar;
  itemPath, outPath: UTF8String;
  errors: LongWord;
begin
  if password <> '' then pw := PAnsiChar(password) else pw := nil;
  a := Sz_OpenFileEx(PAnsiChar(archive), pw, @err);
  if a = nil then
    Die('open: ' + Sz_ErrorString(err));
  errors := 0;
  try
    n := 0;
    Sz_GetItemCount(a, n);
    for i := 0 to n - 1 do
    begin
      size := 0; isDir := 0;
      Sz_GetItemInfo(a, i, @size, @isDir, nil, nil, nil);
      itemPath := Sz_ItemPath(a, i);
      outPath := IncludeTrailingPathDelimiter(destDir) + itemPath;
      { the library creates parent directories as needed }
      r := Sz_ExtractToFile(a, i, PAnsiChar(outPath));
      if r = SZA_OK then
        WriteLn('  ok   ', itemPath)
      else
      begin
        WriteLn('  FAIL ', itemPath, '  (', Sz_ErrorString(r), ')');
        Inc(errors);
      end;
    end;
  finally
    Sz_Close(a);
  end;
  WriteLn(Format('extracted %d item(s) to %s, %d error(s)', [n, destDir, errors]));
  if errors <> 0 then Halt(1);
end;

{ ---- extract one item to memory (demo of Sz_ExtractToBuffer) ---- }
procedure CmdExtractBuffer(const archive: string; index: LongWord; const password: string);
var
  a: TSzArchive;
  err, isDir, r: LongInt;
  n: LongWord;
  size, written: QWord;
  buf: array of Byte;
  pw: PAnsiChar;
begin
  if password <> '' then pw := PAnsiChar(password) else pw := nil;
  a := Sz_OpenFileEx(PAnsiChar(archive), pw, @err);
  if a = nil then
    Die('open: ' + Sz_ErrorString(err));
  try
    n := 0;
    Sz_GetItemCount(a, n);
    if index >= n then
      Die(Format('index %d out of range (0..%d)', [index, n - 1]));
    size := 0; isDir := 0;
    Sz_GetItemInfo(a, index, @size, @isDir, nil, nil, nil);
    if isDir <> 0 then
      Die('item is a directory');
    SetLength(buf, size);
    written := 0;
    if size = 0 then
      r := Sz_ExtractToBuffer(a, index, nil, 0, @written)
    else
      r := Sz_ExtractToBuffer(a, index, @buf[0], size, @written);
    if r <> SZA_OK then
      Die('extract: ' + Sz_ErrorString(r));
    WriteLn(Format('item %d "%s": %d bytes extracted to memory',
      [index, Sz_ItemPath(a, index), written]));
  finally
    Sz_Close(a);
  end;
end;

{ ---- create ---- }
procedure CmdCreate(const outArc, password: string; firstFileArg: Integer);
var
  w: TSzWriter;
  i, r: LongInt;
  pw: PAnsiChar;
  added: LongWord;
  src: string;
begin
  if password <> '' then pw := PAnsiChar(password) else pw := nil;
  w := Sz_CreateArchive(PAnsiChar(outArc), 5, pw);
  if w = nil then
    Die('cannot start archive ' + outArc);
  added := 0;
  for i := firstFileArg to ParamCount do
  begin
    src := ParamStr(i);
    r := Sz_AddFile(w, PAnsiChar(src), nil);
    if r = SZA_OK then
    begin
      WriteLn('  + ', src);
      Inc(added);
    end
    else
      WriteLn('  ! ', src, '  (', Sz_ErrorString(r), ')');
  end;
  r := Sz_FinishArchive(w);
  if r <> SZA_OK then
    Die('finish: ' + Sz_ErrorString(r));
  WriteLn(Format('created %s with %d file(s)%s',
    [outArc, added, BoolToStr(password <> '', ' (encrypted)', '')]));
end;

procedure Usage;
begin
  WriteLn('lib7za test driver (', Sz_VersionString, ')');
  WriteLn('usage:');
  WriteLn('  test7za l  <archive.7z> [password]');
  WriteLn('  test7za x  <archive.7z> <destdir> [password]');
  WriteLn('  test7za xb <archive.7z> <index> [password]');
  WriteLn('  test7za c  <out.7z> <file> [file ...]');
  WriteLn('  test7za cp <password> <out.7z> <file> [file ...]');
  Halt(2);
end;

var
  cmd: string;
begin
  Sz_GlobalInit;
  if ParamCount < 1 then
    Usage;
  cmd := ParamStr(1);

  if (cmd = 'l') and (ParamCount >= 2) then
    CmdList(ParamStr(2), ParamStr(3))
  else if (cmd = 'x') and (ParamCount >= 3) then
    CmdExtract(ParamStr(2), ParamStr(3), ParamStr(4))
  else if (cmd = 'xb') and (ParamCount >= 3) then
    CmdExtractBuffer(ParamStr(2), LongWord(StrToInt64(ParamStr(3))), ParamStr(4))
  else if (cmd = 'c') and (ParamCount >= 3) then
    CmdCreate(ParamStr(2), '', 3)
  else if (cmd = 'cp') and (ParamCount >= 4) then
    CmdCreate(ParamStr(3), ParamStr(2), 4)
  else
    Usage;
end.
