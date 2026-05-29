/* example.c -- minimal C usage of lib7za (Phase 1).

   Build (after building lib7za.so, see README.md), from this directory:
     cc example.c -L b/g_x64 -l7za -Wl,-rpath,'$ORIGIN/b/g_x64' -o example
   or just link against the .so directly:
     cc example.c b/g_x64/lib7za.so -o example
   Run:
     ./example archive.7z
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "SevenZipLib.h"

/* Create mode: example c out.7z file1 [file2 ...] */
static int do_create(int argc, char **argv)
{
  SzWriter w = Sz_CreateArchive(argv[2], 5, NULL);
  if (!w)
  {
    fprintf(stderr, "cannot start archive\n");
    return 1;
  }
  for (int i = 3; i < argc; i++)
  {
    int r = Sz_AddFile(w, argv[i], NULL);
    if (r != SZA_OK)
      fprintf(stderr, "add %s: %s\n", argv[i], Sz_ErrorString(r));
  }
  /* a generated in-memory entry, just to show Sz_AddBuffer */
  const char *note = "created by lib7za example\n";
  Sz_AddBuffer(w, "note.txt", note, (uint64_t)strlen(note), 0);

  int rc = Sz_FinishArchive(w);
  printf("create %s: %s\n", argv[2], Sz_ErrorString(rc));
  return rc == SZA_OK ? 0 : 1;
}

int main(int argc, char **argv)
{
  if (argc < 2)
  {
    fprintf(stderr,
        "usage:\n"
        "  %s archive.7z [password]      list + extract-to-memory demo\n"
        "  %s c out.7z file1 [file2 ...] create an archive\n",
        argv[0], argv[0]);
    return 2;
  }

  Sz_GlobalInit();
  printf("7-Zip lib version: %s\n", Sz_VersionString());

  if (argv[1][0] == 'c' && argv[1][1] == 0)
  {
    if (argc < 4)
    {
      fprintf(stderr, "usage: %s c out.7z file1 [file2 ...]\n", argv[0]);
      return 2;
    }
    return do_create(argc, argv);
  }

  int err = 0;
  SzArchive a = Sz_OpenFileEx(argv[1], argc > 2 ? argv[2] : NULL, &err);
  if (!a)
  {
    fprintf(stderr, "open failed: %s\n", Sz_ErrorString(err));
    return 1;
  }

  uint32_t count = 0;
  Sz_GetItemCount(a, &count);
  printf("%u items\n", count);

  for (uint32_t i = 0; i < count; i++)
  {
    char path[4096];
    uint64_t size = 0;
    int isDir = 0;
    Sz_GetItemPath(a, i, path, (int)sizeof(path), NULL);
    Sz_GetItemInfo(a, i, &size, &isDir, NULL, NULL, NULL);
    printf("  [%u] %s%s  (%llu bytes)\n",
        i, path, isDir ? "/" : "", (unsigned long long)size);
  }

  /* Extract the first regular file into memory as a demo. */
  for (uint32_t i = 0; i < count; i++)
  {
    int isDir = 0;
    uint64_t size = 0;
    Sz_GetItemInfo(a, i, &size, &isDir, NULL, NULL, NULL);
    if (isDir)
      continue;

    void *buf = malloc(size ? (size_t)size : 1);
    uint64_t written = 0;
    int r = Sz_ExtractToBuffer(a, i, buf, size, &written);
    if (r == SZA_OK)
      printf("extracted item %u to memory: %llu bytes\n",
          i, (unsigned long long)written);
    else
      printf("extract item %u failed: %s\n", i, Sz_ErrorString(r));
    free(buf);
    break;
  }

  Sz_Close(a);
  return 0;
}
