@import Foundation;

#import "zip.h"

typedef void (^ImageBlock)(NSData* data, NSString* type);

static void _callback(CGPDFScannerRef scanner, void* info) {
  const void** params = (const void**)info;
  ImageBlock block = (__bridge ImageBlock)params[0];
  
  const char* name;
  assert(CGPDFScannerPopName(scanner, &name));
  CGPDFContentStreamRef stream = CGPDFScannerGetContentStream(scanner);
  CGPDFObjectRef object = CGPDFContentStreamGetResource(stream, "XObject", name);
  assert(object);
  CGPDFStreamRef objectStream;
  assert(CGPDFObjectGetValue(object, kCGPDFObjectTypeStream, &objectStream));
  CGPDFDictionaryRef objectDictionary = CGPDFStreamGetDictionary(objectStream);
  assert(objectDictionary);
  
  const char* subtype;
  assert(CGPDFDictionaryGetName(objectDictionary, "Subtype", &subtype));
  assert(strcmp(subtype, "Image") == 0);
  
  CGPDFDataFormat format;
  CFDataRef data = CGPDFStreamCopyData(objectStream, &format);
  assert(data);
  @autoreleasepool {
    switch (format) {
      
      case CGPDFDataFormatRaw: {
        CGPDFInteger bpc;
        assert(CGPDFDictionaryGetInteger(objectDictionary, "BitsPerComponent", &bpc));
        CGPDFInteger width;
        assert(CGPDFDictionaryGetInteger(objectDictionary, "Width", &width));
        CGPDFInteger height;
        assert(CGPDFDictionaryGetInteger(objectDictionary, "Height", &height));
        CGColorSpaceRef colorSpace;
        const char* csName;
        if (CGPDFDictionaryGetName(objectDictionary, "ColorSpace", &csName)) {
          if (!strcmp(csName, "DeviceGray")) {
            colorSpace = CGColorSpaceCreateDeviceGray();
          } else if (!strcmp(csName, "DeviceRGB")) {
            colorSpace = CGColorSpaceCreateDeviceRGB();
          } else {
            assert(false);
          }
          assert(width * height * CGColorSpaceGetNumberOfComponents(colorSpace) * bpc / 8 == CFDataGetLength(data));
        } else {
          assert(bpc == 8);
          if (width * height == CFDataGetLength(data)) {
            colorSpace = CGColorSpaceCreateDeviceGray();
          } else if (width * height * 3 == CFDataGetLength(data)) {
            colorSpace = CGColorSpaceCreateDeviceRGB();
          } else {
            assert(false);
          }
        }
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
        CGImageRef image = CGImageCreate(width, height, bpc, CGColorSpaceGetNumberOfComponents(colorSpace) * bpc, CGColorSpaceGetNumberOfComponents(colorSpace) * width, colorSpace, kCGImageAlphaNone, provider, NULL, false, kCGRenderingIntentDefault);
        assert(image);
        NSMutableData* buffer = [[NSMutableData alloc] initWithCapacity:CFDataGetLength(data)];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData((CFMutableDataRef)buffer, kUTTypePNG, 1, NULL);
        assert(destination);
        CGImageDestinationAddImage(destination, image, NULL);
        assert(CGImageDestinationFinalize(destination));
        block(buffer, @"png");
        CFRelease(destination);
        CGImageRelease(image);
        CGDataProviderRelease(provider);
        CGColorSpaceRelease(colorSpace);
        break;
      }
      
      case CGPDFDataFormatJPEGEncoded:
        block((__bridge NSData*)data, @"jpg");
        break;
      
      case CGPDFDataFormatJPEG2000:
        block((__bridge NSData*)data, @"jp2");
        break;
      
    }
  }
  CFRelease(data);
}

int main(int argc, const char* argv[]) {
  CGPDFOperatorTableRef table = CGPDFOperatorTableCreate();
  assert(table);
  CGPDFOperatorTableSetCallback(table, "Do", &_callback);
  
  BOOL force = NO;
  for (int i = 1; i < argc; ++i) {
    const char* arg = argv[i];
    if (arg[0] == '-') {
      if (!strcmp(arg, "--force") || !strcmp(arg, "-f")) {
        force = YES;
      }
      continue;
    }
    @autoreleasepool {
      NSString* inPath = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:arg length:strlen(arg)];
      if ([inPath.pathExtension caseInsensitiveCompare:@"pdf"] == NSOrderedSame) {
        NSString* outPath = [[inPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"cbz"];
        if (force || ![[NSFileManager defaultManager] fileExistsAtPath:outPath]) {
          CGPDFDocumentRef document = CGPDFDocumentCreateWithURL((CFURLRef)[NSURL fileURLWithPath:inPath isDirectory:NO]);
          if (document && !CGPDFDocumentIsEncrypted(document) && CGPDFDocumentIsUnlocked(document)) {
            zipFile* file = zipOpen(outPath.fileSystemRepresentation, false);
            if (file) {
              size_t count = CGPDFDocumentGetNumberOfPages(document);
              printf("Processing %lu pages in \"%s\"...\n", count, inPath.UTF8String);
              
              __block int result = Z_OK;
              for (size_t j = 1; j <= count; ++j) {
                CGPDFPageRef page = CGPDFDocumentGetPage(document, j);
                CGPDFContentStreamRef stream = CGPDFContentStreamCreateWithPage(page);
                assert(stream);
                __block NSUInteger imageCount = 0;
                ImageBlock block = ^(NSData* data, NSString* type) {
                  zip_fileinfo info = {{0}};
                  time_t current;
                  time(&current);
                  info.dosDate = (unsigned long)current;
                  result = zipOpenNewFileInZip(file, [[NSString stringWithFormat:@"%lu.%@", j, type] UTF8String], &info, NULL, 0, NULL, 0, NULL, Z_DEFLATED, Z_NO_COMPRESSION);  // No need to recompress images and don't use -fileSystemRepresentation on purpose
                  if (result == Z_OK) {
                    result = zipWriteInFileInZip(file, data.bytes, (unsigned int)data.length);
                  }
                  if (result == Z_OK) {
                    result = zipCloseFileInZip(file);
                  }
                  imageCount += 1;
                };
                const void* params[] = {(__bridge const void*)block};
                CGPDFScannerRef scanner = CGPDFScannerCreate(stream, table, params);
                assert(scanner);
                assert(CGPDFScannerScan(scanner));
                CGPDFScannerRelease(scanner);
                CGPDFContentStreamRelease(stream);
                if (result != Z_OK) {
                  printf("ERROR: Failed saving image from page %lu into ZIP file at \"%s\" (%i)\n", j, outPath.UTF8String, result);
                  break;
                }
                if (imageCount > 1) {
                  printf("ERROR: Page %lu contains multiple images\n", j);
                  result = Z_ERRNO;  // Doesn't matter
                  break;
                }
                if (imageCount < 1) {
                  printf("WARNING: Page %lu contains no image\n", j);
                }
              }
              
              if (result == Z_OK) {
                result = zipClose(file, NULL);
                if (result != Z_OK) {
                  unlink(outPath.fileSystemRepresentation);
                  printf("ERROR: Failed closing ZIP file at \"%s\" (%i)\n", outPath.UTF8String, result);
                }
              } else {
                zipClose(file, NULL);
                unlink(outPath.fileSystemRepresentation);
              }
            } else {
              printf("ERROR: Failed creating ZIP file at \"%s\"\n", outPath.UTF8String);
            }
          } else {
            printf("ERROR: Encrypted or corrupted PDF file at \"%s\"\n", inPath.UTF8String);
          }
          CGPDFDocumentRelease(document);
        } else {
          printf("ERROR: CBZ file already exists at \"%s\"\n", outPath.UTF8String);
        }
      } else {
        printf("ERROR: Ignoring non-PDF file at \"%s\"\n", inPath.UTF8String);
      }
    }
  }
  printf("Done!\n");
  
  CGPDFOperatorTableRelease(table);
  return 0;
}
