/*
 * HelloWorld.c - Minimal KMDF driver for EWDK build validation.
 *
 * Purpose: prove the BUILD pipeline routes requests to EWDK msbuild
 * and produces a .sys artifact. Does not install or bind to real hardware.
 * Target device: USB\VID_FFFF&PID_FFFF (non-existent; build-only test).
 *
 * Reference: Microsoft KMDF hello-world sample (WDK samples/kmdf/hello_kmdf)
 */

#include <ntddk.h>
#include <wdf.h>

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD HelloWorldEvtDeviceAdd;

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT  DriverObject,
    _In_ PUNICODE_STRING RegistryPath
    )
{
    WDF_DRIVER_CONFIG config;
    NTSTATUS          status;

    WDF_DRIVER_CONFIG_INIT(&config, HelloWorldEvtDeviceAdd);

    status = WdfDriverCreate(DriverObject,
                             RegistryPath,
                             WDF_NO_OBJECT_ATTRIBUTES,
                             &config,
                             WDF_NO_HANDLE);
    return status;
}

NTSTATUS
HelloWorldEvtDeviceAdd(
    _In_    WDFDRIVER       Driver,
    _Inout_ PWDFDEVICE_INIT DeviceInit
    )
{
    NTSTATUS   status;
    WDFDEVICE  device;

    UNREFERENCED_PARAMETER(Driver);

    status = WdfDeviceCreate(&DeviceInit,
                             WDF_NO_OBJECT_ATTRIBUTES,
                             &device);
    return status;
}
