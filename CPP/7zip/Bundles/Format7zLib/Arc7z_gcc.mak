# Arc7z_gcc.mak
# Object list for the 7za (.7z only) code base, gcc/clang build.
# This is the reduced counterpart of Bundles/Format7zF/Arc_gcc.mak:
# it keeps only the 7z handler plus the codecs that 7z archives use
# (LZMA, LZMA2, PPMd, BCJ/BCJ2, Delta, Copy, Deflate-decode, BZip2-decode, AES).
#
# Object compile rules for every name below live in ../../7zip_gcc.mak.

include ../../LzmaDec_gcc.mak

COMMON_OBJS = \
  $O/CRC.o \
  $O/CrcReg.o \
  $O/IntToString.o \
  $O/LzFindPrepare.o \
  $O/MyString.o \
  $O/MyVector.o \
  $O/NewHandler.o \
  $O/Sha256Prepare.o \
  $O/Sha256Reg.o \
  $O/StringConvert.o \
  $O/StringToInt.o \
  $O/UTFConvert.o \
  $O/Wildcard.o \

WIN_OBJS = \
  $O/FileDir.o \
  $O/FileFind.o \
  $O/FileIO.o \
  $O/FileName.o \
  $O/PropVariant.o \
  $O/PropVariantConv.o \
  $O/Synchronization.o \
  $O/System.o \
  $O/TimeUtils.o \

7ZIP_COMMON_OBJS = \
  $O/CreateCoder.o \
  $O/CWrappers.o \
  $O/InBuffer.o \
  $O/InOutTempBuffer.o \
  $O/FileStreams.o \
  $O/FilterCoder.o \
  $O/LimitedStreams.o \
  $O/MethodId.o \
  $O/MethodProps.o \
  $O/OutBuffer.o \
  $O/ProgressUtils.o \
  $O/PropId.o \
  $O/StreamBinder.o \
  $O/StreamObjects.o \
  $O/StreamUtils.o \
  $O/UniqBlocks.o \
  $O/VirtThread.o \

AR_OBJS = \
  $O/ArchiveExports.o \
  $O/DllExports2.o \

AR_COMMON_OBJS = \
  $O/CoderMixer2.o \
  $O/HandlerOut.o \
  $O/InStreamWithCRC.o \
  $O/ItemNameUtils.o \
  $O/OutStreamWithCRC.o \
  $O/ParseProperties.o \

7Z_OBJS = \
  $O/7zCompressionMode.o \
  $O/7zDecode.o \
  $O/7zEncode.o \
  $O/7zExtract.o \
  $O/7zFolderInStream.o \
  $O/7zHandler.o \
  $O/7zHandlerOut.o \
  $O/7zHeader.o \
  $O/7zIn.o \
  $O/7zOut.o \
  $O/7zProperties.o \
  $O/7zSpecStream.o \
  $O/7zUpdate.o \
  $O/7zRegister.o \

COMPRESS_OBJS = \
  $O/CodecExports.o \
  $O/Bcj2Coder.o \
  $O/Bcj2Register.o \
  $O/BcjCoder.o \
  $O/BcjRegister.o \
  $O/BitlDecoder.o \
  $O/BranchMisc.o \
  $O/BranchRegister.o \
  $O/ByteSwap.o \
  $O/BZip2Crc.o \
  $O/BZip2Decoder.o \
  $O/BZip2Register.o \
  $O/CopyCoder.o \
  $O/CopyRegister.o \
  $O/DeflateDecoder.o \
  $O/DeflateRegister.o \
  $O/DeltaFilter.o \
  $O/Lzma2Decoder.o \
  $O/Lzma2Encoder.o \
  $O/Lzma2Register.o \
  $O/LzmaDecoder.o \
  $O/LzmaEncoder.o \
  $O/LzmaRegister.o \
  $O/LzOutWindow.o \
  $O/PpmdDecoder.o \
  $O/PpmdEncoder.o \
  $O/PpmdRegister.o \

CRYPTO_OBJS = \
  $O/7zAes.o \
  $O/7zAesRegister.o \
  $O/MyAes.o \
  $O/MyAesReg.o \
  $O/RandGen.o \

C_OBJS = \
  $O/7zCrc.o \
  $O/7zCrcOpt.o \
  $O/7zStream.o \
  $O/Aes.o \
  $O/AesOpt.o \
  $O/Alloc.o \
  $O/Bcj2.o \
  $O/Bcj2Enc.o \
  $O/Bra.o \
  $O/Bra86.o \
  $O/BraIA64.o \
  $O/BwtSort.o \
  $O/CpuArch.o \
  $O/Delta.o \
  $O/HuffEnc.o \
  $O/LzFind.o \
  $O/LzFindMt.o \
  $O/LzFindOpt.o \
  $O/Lzma2Dec.o \
  $O/Lzma2DecMt.o \
  $O/Lzma2Enc.o \
  $O/LzmaDec.o \
  $O/LzmaEnc.o \
  $O/MtCoder.o \
  $O/MtDec.o \
  $O/Ppmd7.o \
  $O/Ppmd7Dec.o \
  $O/Ppmd7Enc.o \
  $O/Sha256.o \
  $O/Sha256Opt.o \
  $O/Sort.o \
  $O/SwapBytes.o \
  $O/Threads.o \

ARC_OBJS = \
  $(LZMA_DEC_OPT_OBJS) \
  $(C_OBJS) \
  $(COMMON_OBJS) \
  $(WIN_OBJS) \
  $(7ZIP_COMMON_OBJS) \
  $(AR_OBJS) \
  $(AR_COMMON_OBJS) \
  $(7Z_OBJS) \
  $(COMPRESS_OBJS) \
  $(CRYPTO_OBJS) \

# we need empty line after last line above
