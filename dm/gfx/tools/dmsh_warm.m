// Warms this Mac's Metal cache for folded pixel shaders (dmsh_build.py fold_try): the host specializes a library's functions that declare constants with an empty set of values
// (nvn_mtl.m shader_load), and the first such specialization of a folded shader takes tens of milliseconds (40 ms on average, up to 200, on Hyrule Warriors: Age of Calamity's).
// Metal keeps the result in the user's cache keyed by the library's contents, whatever its path or the program asking, so doing it here once spares the game that wait at the
// first draw of each. Usage: dmsh_warm < library paths, one per line. Prints one line: how many functions, how long. Built and run by dmsh_build.py (warm_folded)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdatomic.h>

int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { fprintf(stderr, "dmsh_warm: no Metal device\n"); return 1; }
    NSData *in = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    NSArray<NSString *> *paths = [[[[NSString alloc] initWithData:in encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\n"]
                                  filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    __block _Atomic int fns = 0, failed = 0;
    NSDate *t0 = [NSDate date];
    dispatch_apply(paths.count, DISPATCH_APPLY_AUTO, ^(size_t i) { @autoreleasepool {
        NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:paths[i]] error:&e];
        if (!lib) { atomic_fetch_add(&failed, 1); return; }
        for (NSString *name in lib.functionNames) {
            id<MTLFunction> f = [lib newFunctionWithName:name];
            if (!f.functionConstantsDictionary.count) continue;
            if ([lib newFunctionWithName:name constantValues:[MTLFunctionConstantValues new] error:&e]) atomic_fetch_add(&fns, 1); else atomic_fetch_add(&failed, 1);
        }
    } });
    printf("%d functions of %lu folded libraries specialized as the host does (empty set of values), %.1f s%s\n", atomic_load(&fns), (unsigned long)paths.count,
           -t0.timeIntervalSinceNow, atomic_load(&failed) ? [NSString stringWithFormat:@"; %d failed", atomic_load(&failed)].UTF8String : "");
    return 0;
} }
