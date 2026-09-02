// SPDX-License-Identifier: MIT
//
// kernel-stubs.h — minimal userland shims for kernel types/macros used by the
// pure-logic functions under test (ScanForSdpHidDescriptor, PatchSdpHidDescriptor,
// TranslateReport12, ClampInt8, TouchX, TouchY).
//
// Usage: include this file BEFORE the production C file (or function-copy) in
// any userland test binary. It deliberately provides only what the tested
// functions need — not a general-purpose kernel emulation layer.
//
// Tested on: GCC 9+ and Clang 10+ on Linux x86-64 (WSL2).

#pragma once

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// ---------------------------------------------------------------------------
// SAL annotations — stripped to nothing in userland
// ---------------------------------------------------------------------------

#define _In_
#define _In_opt_
#define _Inout_
#define _Out_
#define _Out_opt_
#define _Outptr_
#define _In_reads_bytes_(x)
#define _Inout_updates_bytes_(x)
#define _Out_writes_bytes_(x)
#define _Out_writes_(x)
#define _In_reads_(x)
#define UNREFERENCED_PARAMETER(x)  ((void)(x))

// ---------------------------------------------------------------------------
// Primitive Windows types
// ---------------------------------------------------------------------------

typedef unsigned char       UCHAR;
typedef unsigned char      *PUCHAR;
typedef unsigned long       ULONG;
typedef unsigned long      *PULONG;
typedef int                 BOOLEAN;
typedef void                VOID;
typedef void               *PVOID;
typedef signed int          INT32;
typedef signed char         INT8;
typedef unsigned short      USHORT;
typedef unsigned int        UINT32;
typedef uintptr_t           ULONG_PTR;
typedef size_t              SIZE_T;

#define TRUE  1
#define FALSE 0

// ---------------------------------------------------------------------------
// Compiler hints
// ---------------------------------------------------------------------------

#ifdef _MSC_VER
#define FORCEINLINE __forceinline
#else
#define FORCEINLINE __attribute__((always_inline)) inline
#endif

// ---------------------------------------------------------------------------
// Kernel memory functions → CRT equivalents
// ---------------------------------------------------------------------------

#define RtlMoveMemory(dst, src, n)  memmove((dst), (src), (n))
#define RtlCopyMemory(dst, src, n)  memcpy((dst), (src), (n))
#define RtlZeroMemory(dst, n)       memset((dst), 0, (n))

// ---------------------------------------------------------------------------
// Kernel debug print → stdout
// ---------------------------------------------------------------------------

#define DbgPrint(fmt, ...)          printf("[DbgPrint] " fmt, ##__VA_ARGS__)

// ---------------------------------------------------------------------------
// WDF / KMDF types — not used by the pure-logic functions but present in
// the file-level includes of InputHandler.h / Driver.h. Stub them so the
// preprocessor doesn't choke if the test includes those headers.
// ---------------------------------------------------------------------------

typedef void *WDFDEVICE;
typedef void *WDFREQUEST;
typedef void *WDFIOTARGET;
typedef void *WDFCONTEXT;
typedef void *PIRP;
typedef void *PMDL;
typedef long  NTSTATUS;

// WDF_DECLARE_CONTEXT_TYPE_WITH_NAME expands to struct + accessor.
// We don't need GetDeviceContext() in our tests — define it away.
#define WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(type, accessor)   \
    static inline type *accessor(WDFDEVICE _d) {             \
        (void)_d; return NULL;                               \
    }

// Kernel type we don't use in tested functions — silence typedef errors.
typedef struct { int dummy; } _DEVICE_CONTEXT;
typedef _DEVICE_CONTEXT *PDEVICE_CONTEXT;

