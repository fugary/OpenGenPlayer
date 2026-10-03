#ifndef GenPlayerFontSupport_h
#define GenPlayerFontSupport_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

extern BOOL g_GenPlayerCJKFontInterceptorEnabled;

void GenPlayerInstallCJKFontInterceptor(void);

#ifdef __cplusplus
}
#endif

#endif /* GenPlayerFontSupport_h */
